import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The album page (V-ALBD, DEC-019/020, UC-LAYOUT-05/06) — pushed from the grid, from a track's
/// `Go to Album` or from its Album column (Back ⌘[ returns). In the content scaffold, top to
/// bottom: the drive banner, the header (160 pt cover — drop target, `Choose Cover…` —, kind,
/// title, album artist, facts line with the edition picker, `Play` · `Shuffle` · `More`), one
/// status line when the album isn't complete (IMP-076), the shared track table in the album's own
/// order (no sorting, UC-TABLE-04) with `Not in library` positions and a heading per disc, and
/// the Other versions shelf. Edit Order (IMP-081) swaps the status line for its bar.
///
/// States: loading (the real frame with `Loading…` and disabled Play / Shuffle), not found, error.
struct AlbumDetailView: View {
    let albumID: Int64
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container

    @State private var model: AlbumDetailModel?

    var body: some View {
        Group {
            if let model {
                AlbumDetailPage(model: model, onTrackActivated: onTrackActivated)
            } else {
                ContentScaffold(showsDriveBanner: true) {
                    Color.clear
                } header: {
                    loadingHeader
                }
                .modifier(WindowTitleModifier())
            }
        }
        .task(id: albumID) {
            if model == nil || model?.routeID != albumID {
                model = AlbumDetailModel(albumID: albumID, albums: container.albumRepository)
            }
            await model?.load()
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .bottom, spacing: Spacing.l) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary)
                .frame(width: 160, height: 160)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Album").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("Loading…").font(.largeTitle.bold()).foregroundStyle(.tertiary)
                HStack {
                    Button("Play") {}.buttonStyle(.borderedProminent).disabled(true)
                    Button("Shuffle") {}.disabled(true)
                }
                .padding(.top, Spacing.s)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
    }
}

/// The page once its model exists (and the not-found / error states of a model that failed).
private struct AlbumDetailPage: View {
    let model: AlbumDetailModel
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    @State private var isChoosingCover = false
    @State private var coverRefusal: String?

    private var actions: AlbumActions {
        AlbumActions(container: container, shell: shell, navigation: navigation, statusBar: statusBar, undo: undo)
    }

    private var shownID: Int64 { model.album?.id ?? model.routeID }
    private var filter: SearchFilter { container.searchCoordinator.filter(for: .album(model.routeID)) }

    var body: some View {
        switch model.phase {
        case .missing:
            ContentScaffold(showsDriveBanner: false) { AlbumNotFoundView() }
                .modifier(WindowTitleModifier())
        case .failed:
            ContentScaffold(showsDriveBanner: false) {
                ContentUnavailableView {
                    Label("Can’t load the album", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The library database didn’t answer. Your music and your library file are not affected.")
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                    Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                }
            }
            .modifier(WindowTitleModifier())
        case .loading, .loaded:
            loaded
        }
    }

    private var loaded: some View {
        ContentScaffold(showsDriveBanner: true) {
            if model.phase == .loaded {
                AlbumDetailTableArea(model: model, configuration: configuration, callbacks: callbacks)
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                        guard model.isEditingOrder, press.modifiers.contains(.option) else { return .ignored }
                        Task { await model.nudgeSelection(by: press.key == .upArrow ? -1 : 1) }
                        return .handled
                    }
                    .statusBarText(model.isEditingOrder ? "Editing the order of “\(model.album?.title ?? "")”" : nil)
            } else {
                Color.clear
            }
        } header: {
            if model.phase == .loaded {
                AlbumDetailTop(model: model, playReason: playReason, offlineLine: offlineLine, callbacks: callbacks,
                               cover: { cover }, more: { more })
            }
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
        .fileImporter(isPresented: $isChoosingCover, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            setCover(.file(url))
        }
        // Gaps and headings are not tracks: they are never selected into commands.
        .onChange(of: model.list.selection) { _, selection in
            let real = selection.filter { $0 > 0 }
            if real != selection { model.list.selection = real }
        }
        .onChange(of: filter) { _, new in Task { await model.setFilter(new) } }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in Task { await model.load() } }
        .task {
            TrackMenuSources.shared.loadIfNeeded(container: container)
            await model.setFilter(filter)
        }
    }

    // MARK: Header pieces

    private var cover: some View {
        AlbumCoverView(request: model.coverRequest, cornerRadius: 9)
            .frame(width: 160, height: 160)
            // UC-GLASS-02: the album header artwork extends under the sidebar.
            .backgroundExtensionEffect()
            .contextMenu {
                Button("Choose Cover…") { isChoosingCover = true }
            }
            // An image from Finder or a browser sets the cover (undoable); a refusal says so here.
            .dropTarget(.albumCover(id: shownID, name: model.album?.title ?? ""), cornerRadius: 9, sayRefusal: { coverRefusal = $0 })
            .inPlaceRefusal($coverRefusal)
            .accessibilityLabel("Cover of “\(model.album?.title ?? "")”")
    }

    @ViewBuilder
    private var more: some View {
        if let album = model.album {
            let subject = AlbumMenuSubject(id: shownID, title: album.title, albumArtist: album.albumArtist, isCompilation: model.isCompilation)
            AlbumMenu(albums: [subject], place: .more, missing: model.downloadableTracks.count,
                      chooseCover: { isChoosingCover = true },
                      editOrder: model.isEditingOrder ? nil : { Task { await model.beginEditingOrder() } })
        }
    }

    /// Play and Shuffle are always there; disabled with the reason when nothing can play.
    private var playReason: String? {
        if let drive = TrackTableLiveState.drive(container).cantPlayReason { return drive }
        if model.isEditingOrder { return "Finish editing the order first" }
        if model.members.isEmpty { return "This album has no tracks in the library" }
        guard !model.members.contains(where: { $0.track.isLocal }) else { return nil }
        return "Nothing to play yet — no track is downloaded"
    }

    private var offlineLine: String? {
        TrackTableLiveState.drive(container).offlineVolumeName.map(AlbumText.playPaused(volume:))
    }

    // MARK: Table

    private var configuration: TrackListConfiguration {
        let id = shownID
        let name = model.album?.title ?? ""
        let editing = model.isEditingOrder
        var configuration = TrackListConfiguration.album(
            id: id, name: name, isCompilation: model.isCompilation,
            // Only tracks that can be heard queue up; a gap is none (the queue says how many tracks
            // it skipped, IMP-033).
            activate: editing ? nil : { track, queue in onTrackActivated(track, queue.filter { ($0.id ?? 0) > 0 }) },
            remove: { ids in removeFromAlbum(ids) },
            onInsert: editing ? { index, providers, _ in dropped(providers, at: index) } : nil
        )
        if editing { configuration.removeFromContainer = nil }
        configuration.showsDragHandles = editing
        configuration.syntheticRowsMenu = { _ in AnyView(AbsentRowMenu()) }
        return configuration
    }

    private var callbacks: AlbumDetailCallbacks {
        let actions = self.actions
        let id = shownID
        let name = model.album?.title ?? ""
        let search = self.search
        let model = self.model
        let shell = self.shell
        return AlbumDetailCallbacks(
            openArtist: { search?.goToArtist($0) },
            play: { shuffled in actions.play([id], name: name, shuffled: shuffled) },
            chooseEdition: { edition in
                guard let base = model.album.map({ $0.variantOf ?? $0.id }) ?? nil else { return }
                Task {
                    await model.show(edition: edition.id)
                    await shell?.edits.chooseEdition(base: base, selected: edition.id, edition: edition.name, albumTitle: name)
                }
            },
            downloadMissing: { actions.downloadMissing([id]) },
            cancelEditing: { Task { await model.cancelEditingOrder() } },
            finishEditing: { finishEditing() }
        )
    }

    // MARK: Edits

    /// ⌫ / Remove from “‹Album›”: the tracks leave the album — the files and every playlist keep
    /// them; undoable (UC-KEY-17).
    private func removeFromAlbum(_ ids: Set<Int64>) {
        let ordered = model.list.rows.map(\.id).filter { ids.contains($0) && $0 > 0 }
        guard !ordered.isEmpty, let edits = shell?.edits else { return }
        let id = shownID
        Task { _ = try? await edits.removeTracks(fromAlbum: id, trackIDs: ordered) }
    }

    /// Done: one step; the page shows the saved order when the edit lands.
    private func finishEditing() {
        guard let numbered = model.finishEditingOrder(), let edits = shell?.edits else { return }
        let id = shownID
        Task {
            do {
                _ = try await edits.setAlbumLayout(albumID: id, numbered)
            } catch {
                // The center said why in the status bar.
            }
            await model.load()
        }
    }

    private func dropped(_ providers: [NSItemProvider], at index: Int) {
        Task {
            guard let content = await DropLoader.load(providers), case .tracks(let payload) = content else { return }
            await model.dropTracks(payload.trackIDs, atRow: index)
        }
    }

    private func setCover(_ source: CoverSource) {
        guard let edits = shell?.edits else { return }
        let id = shownID
        let name = model.album?.title ?? ""
        let directory = AlbumCoverLoader.coversDirectory(container)
        var scoped: URL?
        if case .file(let url) = source, url.startAccessingSecurityScopedResource() { scoped = url }
        Task {
            if let refusal = await edits.setAlbumCover(source, albumID: id, name: name, coversDirectory: directory) {
                coverRefusal = refusal
            }
            scoped?.stopAccessingSecurityScopedResource()
        }
    }
}

/// The menu of a `Not in library` row (CM-ALBD-ABSENT, IMP-076): only `Use a Track from the
/// Library…`, which arrives with the next package (W4-2b). `Find Online` and `Copy Title —
/// Artist` need the album's tracklist source (§5 Q2): there is no title to look for.
private struct AbsentRowMenu: View {
    var body: some View {
        Button("Use a Track from the Library…") {}
            .disabled(true)
            .help(AlbumMenuModel.nextPackageHelp)
    }
}

/// The album doesn't exist (any more): where a deleted album's page lands.
struct AlbumNotFoundView: View {
    @Environment(NavigationModel.self) private var navigation: NavigationModel?

    var body: some View {
        ContentUnavailableView {
            Label("Album not found", systemImage: "square.stack")
        } description: {
            Text("This album is no longer in the library.")
        } actions: {
            Button("Go to Albums") { navigation?.select(.albums) }
        }
    }
}
