import SwiftUI

// MARK: - Folders (V-FOLD, DEC-024 variant A)

/// The library folder as it is laid out on disk: one hierarchical table (folders with counts,
/// tracks with the All Tracks columns, files that aren't in the library) with a path bar at the
/// bottom. Its own scaffold (like the playlist pages): drive banner, the place's lines (offline
/// hint, filter result, files not in the library), the table, the path bar, the selection bar
/// and the status bar (`12 folders · 1,204 tracks`).
struct FoldersView: View {
    let onTrackActivated: TrackActivation

    @State private var model = FolderModelStore.shared.model()
    @State private var live = TrackTableLive()

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ContentScaffold(showsDriveBanner: true) {
            content
                .statusBarText(statusText)
        } scopeBar: {
            FolderInfoLines(model: model, folderActions: folderActions, clearFilters: clearFilters)
        } selectionBar: {
            // Above the path bar, never over it or the status bar (UC-SELBAR-01).
            TrackSelectionBar()
                .padding(.bottom, model.phase == .ready ? FolderPathBar.height : 0)
        }
        .hostsTrackSelectionBar()
        .navigationTitle(title)
        .navigationSubtitle(LibraryFooter.libraryName(LibraryLaunchCoordinator.shared))
        .focusedSceneValue(\.folderScan, scanCommand)
        .task {
            await model.load()
            model.applyFilter(container.searchCoordinator.filter(for: .folders))
            openRequestedFolder()
        }
        // In-place filter: folders by name, tracks by the track filter (W2-I seam).
        .onChange(of: container.searchCoordinator.filter(for: .folders)) { _, filter in
            model.applyFilter(filter)
        }
        .onChange(of: FolderOpenRequest.shared.path) { _, _ in openRequestedFolder() }
        .onChange(of: LibraryDriveState.current(container)) { _, _ in model.driveStateChanged() }
        .background { FolderRevealTaker(model: model) }
        .onDisappear { model.placeDidDisappear() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryFilesDidChange)) { _ in model.libraryFilesDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in model.libraryFilesDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in model.trackMetadataDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in model.trackMetadataDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { note in
            let ids = (note.userInfo?["removedIds"] as? [Int64]) ?? (note.userInfo?["deletedIDs"] as? [Int64]) ?? []
            model.removeTracks(ids: Set(ids))
        }
    }

    private var title: String {
        model.root.isEmpty ? SidebarDestination.folders.fixedTitle : model.rootName
    }

    // MARK: Content by state (UC §18)

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            FolderPlaceholderTable()
        case .noLibraryFolder:
            ContentUnavailableView {
                Label("No library folder", systemImage: "folder")
            } description: {
                Text("This library has no library folder yet, so there are no folders to show. Choose one in Settings ▸ Library.")
            } actions: {
                Button("Open Settings ▸ Library") { openSettings(tab: .library) }
            }
        case .failed(let kind, let details):
            failure(kind, details: details)
        case .ready:
            VStack(spacing: 0) {
                FolderOutlineTable(model: model, configuration: configuration, actions: trackActions,
                                   folderActions: folderActions, live: live)
                    .overlay {
                        if let empty = emptyState {
                            empty
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                                .dropTarget(.folderRow(path: model.root, name: model.rootName), cornerRadius: 0)
                        }
                    }
                FolderPathBar(model: model)
            }
        }
    }

    /// Filtered-empty (UC-EMPTY-02) or an empty folder.
    private var emptyState: AnyView? {
        if model.isFilteredEmpty {
            let query = model.filter.displayText
            return AnyView(ContentUnavailableView {
                Label("No Results for “\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("No folder or track in “\(model.rootName)” matches “\(query)”.")
            } actions: {
                Button("Clear Filters") { clearFilters() }
                Button("Search the Library") { search?.focus(scope: .library) }
                Button("Search Online") { search?.focus(scope: .online) }
            })
        }
        guard model.filterMatch == nil, model.outline.rows.isEmpty else { return nil }
        if let volume = LibraryDriveState.current(container).isOffline ? LibraryDriveState.current(container).volumeName : nil {
            return AnyView(ContentUnavailableView {
                Label("No library tracks in “\(model.rootName)”", systemImage: "folder")
            } description: {
                Text("Folders without library tracks show when “\(volume)” is connected.")
            })
        }
        return AnyView(ContentUnavailableView {
            Label("“\(model.rootName)” is empty", systemImage: "folder")
        } description: {
            Text("There are no audio files or folders in it. Drop files here to import them.")
        } actions: {
            Button("Import Files or Folder…") { shell?.chooseImportFolder() }
        })
    }

    @ViewBuilder
    private func failure(_ kind: FolderViewModel.FailureKind, details: String) -> some View {
        ContentUnavailableView {
            switch kind {
            case .libraryFolderUnreadable:
                Label("Can’t read the library folder", systemImage: "exclamationmark.triangle")
            case .database:
                Label("Couldn’t load the folders", systemImage: "exclamationmark.triangle")
            }
        } description: {
            switch kind {
            case .libraryFolderUnreadable(let reason):
                Text("MLM couldn’t read “\(model.libraryFolderName)” — \(reason). Your music and your library file are not affected.")
            case .database:
                Text("MLM couldn’t read the library file. Your music is not affected.")
            }
        } actions: {
            Button("Try Again") { Task { await model.load() } }
            if case .libraryFolderUnreadable = kind, let url = model.url("") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
            DisclosureGroup("Details") {
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: The track-table parts

    private var configuration: TrackListConfiguration {
        TrackListConfiguration(
            listContext: .folder(path: model.root, name: model.rootName),
            persistenceKey: "folders",
            columns: FolderOutlineTable.columns,
            defaultSort: TrackSortOrder(column: .title, ascending: true),
            // The status text is the place's own (folders and tracks, `statusText`).
            publishesStatusText: false,
            accessibilityID: "folders_outline_table",
            activate: onTrackActivated
        )
    }

    private var trackActions: TrackListActions {
        TrackListActions(model: model.trackList, configuration: configuration, live: live,
                         statusBar: statusBar, undo: undo, shell: shell, container: container, navigation: navigation)
    }

    private var folderActions: FolderActions {
        FolderActions(model: model, trackActions: trackActions, shell: shell, statusBar: statusBar, undo: undo, container: container)
    }

    // MARK: Status bar (UC-STATUS-02/03)

    /// `12 folders · 1,204 tracks`; with a selection of tracks the shared `‹n› selected · ‹time›`;
    /// one folder `“2026” · 48 tracks`; a mixed selection `‹n› selected`.
    private var statusText: String? {
        let selection = model.trackList.selection
        guard !selection.isEmpty else { return model.statusText }
        let selectedRows = model.outline.order.filter(selection.contains)
        let folders = selectedRows.compactMap { model.folder(id: $0) }
        let tracks = model.trackList.selectedRows(selection)
        guard !selectedRows.isEmpty else { return model.statusText }
        if folders.isEmpty, tracks.count == selectedRows.count {
            let seconds = tracks.reduce(0) { $0 + max($1.track.duration ?? 0, 0) }
            return "\(tracks.count.formatted(.number)) selected · \(TrackDurationText.total(seconds))"
        }
        if folders.count == 1, selectedRows.count == 1 {
            return "“\(folders[0].name)” · \(StatusBarText.tracks(folders[0].trackCount))"
        }
        return "\(selectedRows.count.formatted(.number)) selected"
    }

    // MARK: ⌘R (UC-KEY-15)

    private var scanCommand: FolderScanCommand? {
        guard model.phase == .ready else { return nil }
        let folder = model.headerFolder
        let offline = LibraryDriveState.current(container)
        return FolderScanCommand(
            folderName: FolderPath.name(of: folder, libraryFolderName: model.libraryFolderName),
            disabledReason: offline.isOffline ? offline.volumeName.map(TrackMenu.notConnectedHelp)
                : (model.scanning.contains(folder) ? "This folder is being scanned." : nil),
            perform: { [model] in Task { await model.scan(folder) } }
        )
    }

    // MARK: Search

    private func clearFilters() {
        if let search, search.place.key == .folders {
            search.clear()
        } else {
            container.searchCoordinator.commit(.empty, for: .folders)
        }
        model.applyFilter(SearchFilter())
    }

    /// A folder chosen in the search field's Library results.
    private func openRequestedFolder() {
        guard model.phase == .ready, let path = FolderOpenRequest.shared.take() else { return }
        model.revealFolder(absolutePath: path)
    }
}

/// `Scan This Folder` ⌘R of the visible Folders place (Track ▸ Refresh from Source, UC-KEY-15):
/// the selected folder, else the root.
struct FolderScanCommand {
    let folderName: String
    /// Why it can't run now (drive away, a scan of it runs); nil = enabled.
    let disabledReason: String?
    let perform: @MainActor () -> Void
}

extension FocusedValues {
    /// The Folders place on screen (W3-FOLD): ⌘R scans its folder.
    @Entry var folderScan: FolderScanCommand?
}

// MARK: - The place's lines (UC-LAYOUT-01 scope-bar slot, V-FOLD.E02/E08/N06)

/// One line each, only when it applies: the drive-away consequence for this screen
/// (UC-EMPTY-07), the filter result with `Clear Filters`, the running import's echo
/// (UC-JOB-07), and `‹n› files in this folder aren’t in the library · Import` (§15.9).
private struct FolderInfoLines: View {
    let model: FolderViewModel
    let folderActions: FolderActions
    let clearFilters: () -> Void

    @Environment(\.container) private var container

    var body: some View {
        let drive = LibraryDriveState.current(container)
        VStack(spacing: 0) {
            if model.phase == .ready {
                if drive.isOffline, let volume = drive.volumeName {
                    line(systemImage: "externaldrive.badge.xmark") {
                        Text("Files that aren’t in the library can’t be listed until “\(volume)” is connected.")
                    }
                }
                if let summary = model.filterSummary {
                    line(systemImage: "magnifyingglass") {
                        Text(summary)
                        Spacer(minLength: Spacing.s)
                        Button("Clear Filters", action: clearFilters)
                    }
                }
                importLine
            }
        }
    }

    @ViewBuilder
    private var importLine: some View {
        let folder = model.headerFolder
        if let url = model.url(folder), let echo = ActivityCenter.shared.echo(for: .folder(url)),
           echo.state == .running || echo.state == .queued {
            line(systemImage: "square.and.arrow.down") {
                Text(echo.playlistText)
                    .monospacedDigit()
                if let fraction = echo.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 160)
                }
                Spacer(minLength: Spacing.s)
                Button("Show in Activity") { ActivityRouter.shared.showPopover() }
                    .buttonStyle(.link)
            }
        } else if let files = model.notInLibraryFiles(under: folder), !files.isEmpty {
            line(systemImage: "doc.badge.plus") {
                Text(FolderNotInLibrary.headerText(count: files.count, isLibraryFolder: folder.isEmpty))
                if !folder.isEmpty {
                    Text("“\(FolderPath.name(of: folder, libraryFolderName: model.libraryFolderName))”")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Spacing.s)
                Button("Import") { Task { await model.importNotInLibrary(under: folder) } }
            }
        }
    }

    private func line<Content: View>(systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - First load (UC-TABLE-09)

/// Redacted rows under the real column header while the folders are read the first time.
private struct FolderPlaceholderTable: View {
    var body: some View {
        Table(TrackTablePlaceholders.rows) {
            TableColumn("Name") { row in Text(row.title) }
            TableColumn("Artist") { row in Text(row.artistText ?? "") }
            TableColumn("Album") { row in Text(row.albumText ?? "") }
            TableColumn("Time") { row in Text(row.timeText ?? "") }
            TableColumn("Status") { _ in Text("") }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading folders")
    }
}

// MARK: - Go to Current Track ⌘L (W2-C)

/// Takes a `TrackListReveal` request for Folders: opens the folders above the track, selects it
/// and scrolls to it once its row is shown.
private struct FolderRevealTaker: View {
    let model: FolderViewModel
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    var body: some View {
        let request = TrackListReveal.shared.request.flatMap { request -> TrackListReveal.Request? in
            if case .folder = request.container, request.listKey == "folders" { return request }
            return nil
        }
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: RevealKey(requestID: request?.id, ready: model.phase == .ready, rows: model.trackList.rows.count)) {
                guard let request, model.phase == .ready else { return }
                if model.trackList.row(id: request.trackID) != nil {
                    model.trackList.selection = [request.trackID]
                    model.trackList.scrollTo(request.trackID)
                    TrackListReveal.shared.done(request.id)
                    return
                }
                if !model.reveal(trackID: request.trackID) {
                    TrackListReveal.shared.done(request.id)
                    statusBar?.post(TrackListReveal.absentMessage(title: request.title))
                    return
                }
                // The row appears once its folder's tracks are loaded (a new row count restarts this).
                try? await Task.sleep(for: TrackListReveal.absentGrace)
                guard !Task.isCancelled, TrackListReveal.shared.request?.id == request.id,
                      model.trackList.row(id: request.trackID) == nil else { return }
                TrackListReveal.shared.done(request.id)
                statusBar?.post(TrackListReveal.absentMessage(title: request.title))
            }
    }

    private struct RevealKey: Equatable {
        let requestID: UUID?
        let ready: Bool
        let rows: Int
    }
}
