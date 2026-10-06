import AppKit
import SwiftUI

/// All Playlists (V-PL, DEC-003): the cover view of what the sidebar lists — the same
/// playlists, in the same order when sorted `Manual`, with playlist folders as collapsible
/// groups (no filter, no scope); any other sort, scope or filter shows one flat grid.
///
/// Single click selects, double-click / Return opens (pushed, Back ⌘[), ⌥-double-click or the
/// cover's play badge plays (UC-SEL-04, UC-PRIM-05, §10 Q11). Scope bar `All · Local · ‹sources›
/// · Needs attention` with live counts and the sort control; the toolbar's search filters by
/// name in place. No toolbar items and no New Playlist button: New Playlist lives in the Add
/// menu, the File menu and the Playlists section's ＋ (the naming popover S-PL-NEWPLAYLIST is
/// gone — new playlists are named inline in the sidebar).
///
/// Built on the sidebar's data (`SidebarModel`: tree, summaries, sources) — one query for
/// every playlist, nothing per card.
struct PlaylistsView: View {
    @Environment(\.container) private var container
    @Environment(SidebarModel.self) private var sidebar
    @Environment(NavigationModel.self) private var navigation
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    /// UC-SCOPE-05 / V-PL.N01: remembered per window.
    @SceneStorage("allPlaylists.sort") private var sortRaw = PlaylistGridSort.manual.rawValue
    @SceneStorage("allPlaylists.scope") private var scopeKey = PlaylistGridScope.all.storageKey

    @State private var selection: Set<Int64> = []
    @State private var anchor: Int64?
    @State private var renamingID: Int64?
    @State private var renameText = ""
    @State private var collapsedGroups: Set<Int64> = []
    @State private var refusals: [Int64: String] = [:]
    @FocusState private var gridFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: Spacing.l, alignment: .top)]

    private var sort: PlaylistGridSort { PlaylistGridSort(rawValue: sortRaw) ?? .manual }
    private var filter: SearchFilter { container.searchCoordinator.filter(for: .allPlaylists) }

    private var actions: PlaylistActions {
        PlaylistActions(container: container, shell: shell, navigation: navigation, statusBar: statusBar, undo: undo)
    }

    // MARK: Data

    private var items: [Int64: PlaylistGridItem] {
        let unusable = container.tokenAccessStatus?.inaccessibleServices ?? []
        var result: [Int64: PlaylistGridItem] = [:]
        for playlist in sidebar.playlists {
            guard let id = playlist.id else { continue }
            let sourceName = playlist.sourceId.flatMap { sidebar.sourceNames[$0] }
            let summary = sidebar.summaries[id]
            result[id] = PlaylistGridItem(
                playlist: playlist,
                summary: summary,
                status: PlaylistStatus.make(
                    summary: summary,
                    echo: ActivityCenter.shared.echo(for: .playlist(id, name: playlist.name)),
                    expiredSignIn: PlaylistStatus.expiredSignIn(sourceName: sourceName, unusable: unusable)
                ),
                source: sourceName.map(PlaylistSourceIdentity.init(sourceName:))
            )
        }
        return result
    }

    private func scope(in all: [PlaylistGridItem]) -> PlaylistGridScope {
        PlaylistGridRules.scopes(all).first { $0.storageKey == scopeKey } ?? .all
    }

    // MARK: Body

    var body: some View {
        let items = self.items
        let all = Array(items.values)
        let scope = scope(in: all)
        let layout = PlaylistGridRules.layout(tree: sidebar.tree, items: items, sort: sort, scope: scope, filter: filter)
        ContentScaffold(showsDriveBanner: false) {
            content(layout: layout, all: all, scope: scope)
                .statusBarText(statusText(layout: layout, total: all.count, items: items))
        } scopeBar: {
            if sidebar.hasLoadedPlaylists && !sidebar.playlists.isEmpty {
                ScopeBar(
                    items: PlaylistGridRules.scopes(all).map { scope in
                        ScopeBarItem(id: scope, title: scope.title, count: PlaylistGridRules.count(all, in: scope),
                                     hidesWhenEmpty: scope == .needsAttention)
                    },
                    selection: Binding(get: { scope }, set: { scopeKey = $0.storageKey }),
                    countNoun: .playlists
                ) {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(PlaylistGridSort.allCases) { sort in
                            Text(sort.title).tag(sort.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Sort the playlists")
                }
            }
        }
        .modifier(WindowTitleModifier())
        // Export ▸ Playlist as M3U… with one card selected.
        .focusedSceneValue(\.selectedPlaylists, selection.compactMap { items[$0]?.playlist })
        .onChange(of: PlaylistRequests.shared.revealInGrid) { _, id in reveal(id) }
        .onAppear { reveal(PlaylistRequests.shared.revealInGrid) }
    }

    @ViewBuilder
    private func content(layout: PlaylistGridLayout, all: [PlaylistGridItem], scope: PlaylistGridScope) -> some View {
        if sidebar.playlistLoadFailed && sidebar.playlists.isEmpty {
            ContentUnavailableView {
                Label("Can’t load the playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. Your playlists and your music are not affected.")
            } actions: {
                Button("Try Again") { Task { await sidebar.reloadPlaylists(container.playlistRepository) } }
                Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
            }
        } else if !sidebar.hasLoadedPlaylists {
            placeholderGrid
        } else if sidebar.playlists.isEmpty {
            ContentUnavailableView {
                Label("No playlists yet", systemImage: "music.note.list")
            } description: {
                Text("Create an empty playlist and drag tracks onto it, or import one from SoundCloud, YouTube or Spotify.")
            } actions: {
                Button("New Playlist") { shell?.newPlaylist() }
                    .buttonStyle(.borderedProminent)
                Button("Import Playlist from Source…") { shell?.importPlaylistFromSource() }
            }
            // Drop targets stay active on an empty state (UC-EMPTY-01).
            .dropTarget(.playlistsSection, cornerRadius: 0)
        } else if layout.items.isEmpty && !isGroupedWithFolders(layout) {
            ContentUnavailableView {
                Label("No playlists match", systemImage: "magnifyingglass")
            } description: {
                Text(PlaylistGridRules.filteredEmptyText(query: filter.displayText, scope: scope))
            } actions: {
                Button("Clear Filters") {
                    scopeKey = PlaylistGridScope.all.storageKey
                    search?.clear()
                }
            }
        } else {
            grid(layout)
        }
    }

    private func isGroupedWithFolders(_ layout: PlaylistGridLayout) -> Bool {
        if case .grouped(let groups) = layout { return groups.contains { $0.folder != nil } }
        return false
    }

    /// First load only: placeholder cards under the real scope bar (V-PL.E16, UC-EMPTY-04).
    private var placeholderGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.l) {
                ForEach(0..<12, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                        Text("Playlist name")
                        Text("00 tracks").font(.subheadline)
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .padding(Spacing.xl)
        }
        .accessibilityLabel("Loading playlists")
    }

    private func grid(_ layout: PlaylistGridLayout) -> some View {
        let manualOrder = sort == .manual && scope(in: Array(items.values)) == .all && filter.isEmpty
        let orderedIDs = layout.items.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.m) {
                    switch layout {
                    case .flat(let items):
                        cards(items, manualOrder: false, orderedIDs: orderedIDs)
                    case .grouped(let groups):
                        ForEach(groups) { group in
                            if let folder = group.folder, let folderID = folder.id {
                                folderHeading(folder, id: folderID, count: group.items.count)
                                if !collapsedGroups.contains(folderID) {
                                    cards(group.items, manualOrder: manualOrder, orderedIDs: orderedIDs)
                                }
                            } else {
                                cards(group.items, manualOrder: manualOrder, orderedIDs: orderedIDs)
                            }
                        }
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The grid's background: a new playlist from dropped tracks, playlists back to the
            // top level (D-PL-SELECTION-TO-NEW); the cards take their own drops.
            .dropTarget(.playlistsSection, cornerRadius: 0)
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard renamingID == nil, selection.count == 1, let id = selection.first,
                      let playlist = items[id]?.playlist else { return .ignored }
                actions.open(playlist)
                return .handled
            }
            .onKeyPress(.escape) {
                guard renamingID == nil, !selection.isEmpty else { return .ignored }
                selection = []
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                move(press.key == .rightArrow ? 1 : -1, in: orderedIDs, proxy: proxy)
            }
            .onChange(of: PlaylistRequests.shared.revealInGrid) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func folderHeading(_ folder: PlaylistFolder, id: Int64, count: Int) -> some View {
        Button {
            if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: collapsedGroups.contains(id) ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folder.name).fontWeight(.semibold)
                Text(StatusBarText.playlists(count)).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.s)
        .accessibilityLabel("\(folder.name), \(StatusBarText.playlists(count))")
        .accessibilityValue(collapsedGroups.contains(id) ? "Collapsed" : "Expanded")
        // V-PL.N04: the heading takes dropped playlists (move into the folder).
        .dropTarget(.playlistFolder(id: id, name: folder.name))
        .contextMenu {
            // Rename happens in the folder's sidebar row (its inline field).
            PlaylistFolderMenu(folder: folder) { sidebar.requestRename(folder: id) }
        }
    }

    private func cards(_ items: [PlaylistGridItem], manualOrder: Bool, orderedIDs: [Int64]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.l) {
            ForEach(items) { item in
                card(item, manualOrder: manualOrder, orderedIDs: orderedIDs)
                    .id(item.id)
            }
        }
    }

    private func card(_ item: PlaylistGridItem, manualOrder: Bool, orderedIDs: [Int64]) -> some View {
        let id = item.id
        let playlist = item.playlist
        return PlaylistCard(
            item: item,
            isSelected: selection.contains(id),
            isRenaming: renamingID == id,
            renameText: $renameText,
            onCommitRename: { commitRename(playlist) },
            onCancelRename: { renamingID = nil },
            onPlay: { actions.play(playlist) }
        )
        .inPlaceRefusal(Binding(get: { refusals[id] }, set: { refusals[id] = $0 }))
        .gesture(TapGesture(count: 2).modifiers(.option).onEnded { actions.play(playlist) })
        .gesture(TapGesture(count: 2).onEnded { if renamingID != id { actions.open(playlist) } })
        .simultaneousGesture(TapGesture().onEnded { select(id, in: orderedIDs) })
        .contextMenu {
            let subjects = selection.contains(id) && selection.count > 1
                ? orderedIDs.filter(selection.contains).compactMap { self.items[$0]?.playlist }
                : [playlist]
            PlaylistMenu(playlists: subjects, place: .card) { startRename(playlist) }
        }
        // Tracks / files / links like its sidebar row, an image sets the cover; in Manual order
        // a dragged playlist goes before it (D-PL-CARD-REORDER).
        .dropTarget(
            manualOrder
                ? .playlistCardInManualOrder(id: id, name: playlist.name, folderID: sidebar.tree.folder(containing: id)?.id)
                : .playlistCard(id: id, name: playlist.name),
            cornerRadius: 9,
            sayRefusal: { refusals[id] = $0 }
        )
        .draggable(PlaylistDragItem(playlistId: id, libraryId: container.activeLibrary?.libraryId))
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

    private func move(_ step: Int, in ordered: [Int64], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard renamingID == nil, !ordered.isEmpty else { return .ignored }
        let current = anchor.flatMap { ordered.firstIndex(of: $0) } ?? -step
        let next = min(max(current + step, 0), ordered.count - 1)
        selection = [ordered[next]]
        anchor = ordered[next]
        proxy.scrollTo(ordered[next])
        return .handled
    }

    private func reveal(_ id: Int64?) {
        guard let id else { return }
        scopeKey = PlaylistGridScope.all.storageKey
        if let folder = sidebar.tree.folder(containing: id)?.id { collapsedGroups.remove(folder) }
        selection = [id]
        anchor = id
        Task { @MainActor in PlaylistRequests.shared.revealInGrid = nil }
    }

    // MARK: Rename (V-PL.E11)

    private func startRename(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        renameText = playlist.name
        renamingID = id
    }

    private func commitRename(_ playlist: Playlist) {
        guard renamingID == playlist.id, let id = playlist.id else { return }
        renamingID = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty or unchanged keeps the old name (UC-KEY-20).
        guard !name.isEmpty, name != playlist.name, let edits = shell?.edits else { return }
        Task {
            do {
                try await edits.renamePlaylist(id, from: playlist.name, to: name)
            } catch {
                statusBar?.post(ShellEdits.renameFailure(error, kind: "playlist"))
            }
        }
    }

    // MARK: Status bar (UC-STATUS-02)

    private func statusText(layout: PlaylistGridLayout, total: Int, items: [Int64: PlaylistGridItem]) -> String {
        let chosen = selection.compactMap { items[$0] }
        if chosen.count == 1, let one = chosen.first {
            return "“\(one.playlist.name)” selected · \(StatusBarText.tracks(one.trackCount))"
        }
        if chosen.count > 1 {
            return "\(StatusBarText.playlists(chosen.count)) selected · \(StatusBarText.tracks(chosen.reduce(0) { $0 + $1.trackCount }))"
        }
        return PlaylistGridRules.statusText(shown: layout.items.count, total: total)
    }
}
