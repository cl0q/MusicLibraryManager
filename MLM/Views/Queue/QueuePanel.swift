import AppKit
import SwiftUI

/// The Queue mode of the trailing column (P-QUEUE, UC-TRAIL-05, DEC-006): a plain native
/// `List` in the system inspector — `Now playing`, `Next` (Play Next items, then
/// `From “‹context›”`), `History` (most recent first) — with system section headers.
///
/// - Rows: cover, title, artist, time; a state word only when the row can't play now (from
///   persisted availability and the drive — never a disk probe, UC-TABLE-20); dimmed only when
///   its disk is away (UC-TABLE-10).
/// - Every row is a queue entry with its own identity: the same track twice is two rows.
/// - Return / double-click plays the row (UC-PRIM-12), ⌫ removes Next rows (undoable, no
///   question, DEC-050), Space previews (never touches the queue, IMP-034), ⌘A selects all,
///   drag reorders Next with an insertion line, tracks dropped on Next land at the line (the top
///   is Play Next), `Clear`, `Save as Playlist…`, the safe menu CM-QUEUE.
/// - No selection bar here (UC-SELBAR-05, IMP-032). It never opens by itself (UC-TRAIL-02).
struct QueuePanel: View {
    @Environment(\.container) private var container

    var body: some View {
        if let playback = container.playbackViewModel {
            QueuePanelList(playback: playback)
        } else {
            // V-QUEUE.E05: no player without an open library.
            ContentUnavailableView(QueuePanelWords.unavailableTitle, systemImage: "speaker.slash",
                                   description: Text(QueuePanelWords.unavailableSentence))
        }
    }
}

// MARK: - The list

private struct QueuePanelList: View {
    let playback: PlaybackViewModel

    @State private var selection: Set<UUID> = []
    @State private var showsSave = false
    @Environment(\.container) private var container
    @Environment(UndoCenter.self) private var undoCenter: UndoCenter?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @FocusedValue(\.toolbarSearch) private var search
    /// When the last letter of a type-select was typed (a Space right after belongs to it).
    @State private var typeSelect = TrackListPreviewKeys.TypeSelectClock()

    /// The preview owner of this panel (its selection moves the preview).
    static let previewOwner: PreviewOwner = "queue-panel"

    private var undo: UndoCenter { undoCenter ?? .main }

    var body: some View {
        let live = TrackTableLiveState.drive(container)
        let sources = TrackMenuSources.shared
        let content = QueuePanelContent.make(
            current: playback.currentTrack,
            currentEntryID: playback.currentEntryID,
            queue: playback.queueSnapshot,
            history: playback.historyEntries,
            origin: validatedOrigin,
            live: live,
            repeatsAll: playback.repeatMode == .all,
            listNames: QueuePanelContent.ListNames(playlists: sources.playlists, syncProfiles: sources.syncProfiles)
        )
        List(selection: $selection) {
            Section(QueuePanelWords.nowPlaying) {
                ForEach(content.nowPlaying.map { [$0] } ?? []) { item in
                    QueueRowView(item: item, live: live, isPlaying: playback.isMainPlaying)
                        .itemProvider { Self.provider(for: item) }
                }
                // The top of the panel: tracks dropped here play next (P-QUEUE.N12).
                .dropDestination(for: TrackDragItem.self) { items, _ in
                    QueueEditCommands.drop(TrackDragPayload.queueRows(items, container: container),
                                           at: QueueDropTarget.position(.top), playback: playback, undo: undo,
                                           container: container)
                }
                if content.nowPlaying == nil {
                    QueueEmptyText(title: QueuePanelWords.notPlaying, sentence: nil)
                }
            }
            Section {
                ForEach(content.nextItems) { item in
                    nextRow(item, content: content, live: live)
                }
                // Named by the row the line sits next to, resolved when the drop applies.
                .dropDestination(for: TrackDragItem.self) { items, offset in
                    QueueEditCommands.drop(TrackDragPayload.queueRows(items, container: container),
                                           at: content.dropTarget(forDropAt: offset), playback: playback,
                                           undo: undo, container: container)
                }
            } header: {
                nextHeader(content)
            }
            Section(QueuePanelWords.history) {
                if content.history.isEmpty {
                    QueueEmptyText(title: nil, sentence: QueuePanelWords.noHistory)
                } else {
                    ForEach(content.history) { item in
                        QueueRowView(item: item, live: live, isPlaying: false)
                            .itemProvider { Self.provider(for: item) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids, content: content, live: live)
        } primaryAction: { ids in
            play(ids, content: content)
        }
        // ⌫ removes the selected Next rows (History and Now playing stay, UC-KEY-17).
        .onDeleteCommand {
            remove(content.rows(selection).filter(\.isInNext).map(\.id))
        }
        // Letters typed into the list's type-select (a Space within 0.9 s belongs to it, IMP-034).
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
            if press.modifiers.isDisjoint(with: [.command, .control, .option]) { typeSelect.last = Date() }
            return .ignored
        }
        .onKeyPress(keys: [.space, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            previewKey(press, content: content, live: live)
        }
        // ⌘C: one `Title — Artist` line per selected row (UC-CM-13).
        .onCopyCommand {
            let rows = content.rows(selection)
            guard !rows.isEmpty else { return [] }
            return [NSItemProvider(object: TrackCommandActions.titleArtistLines(rows.map(\.track)) as NSString)]
        }
        .focusedValue(\.trackSelection, trackSelection(content: content, live: live))
        .safeAreaInset(edge: .top, spacing: 0) {
            if let name = live.offlineVolumeName, content.nowPlaying != nil || !content.isNextEmpty {
                driveLine(name)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(content)
        }
        .onChange(of: content.allRows.map(\.id)) { _, ids in
            // Rows that left the queue leave the selection.
            let present = Set(ids)
            if !selection.isSubset(of: present) { selection.formIntersection(present) }
        }
        .onChange(of: selection) { _, ids in
            let rows = content.rows(ids)
            InspectedTrackSelection.shared.update(ShellEdits.uniqued(rows.map(\.row.id)), from: "queue")
            if playback.preview.isActive {
                playback.preview.selectionChanged(owner: Self.previewOwner, candidate: previewCandidate(rows, live: live))
            }
        }
        .onDisappear {
            if playback.preview.owner == Self.previewOwner { playback.preview.ownerGone(Self.previewOwner) }
        }
        .accessibilityIdentifier("queue_panel")
    }

    // MARK: Next

    @ViewBuilder
    private func nextRow(_ item: QueueNextItem, content: QueuePanelContent, live: TrackTableLiveState) -> some View {
        switch item {
        case .entry(let row):
            QueueRowView(item: row, live: live, isPlaying: false)
                .itemProvider { Self.provider(for: row) }
        case .divider:
            contextDivider(content)
                .selectionDisabled()
        case .empty:
            QueueEmptyText(
                title: QueuePanelWords.queueEmptyTitle,
                sentence: QueuePanelWords.queueEmptySentence
                    + (content.playbackStopsAfterCurrent ? " " + QueuePanelWords.stopsAfterThisTrack : "")
            )
            .selectionDisabled()
        }
    }

    private func nextHeader(_ content: QueuePanelContent) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(QueuePanelWords.next)
            if !content.isNextEmpty {
                Text(QueuePanelWords.nextSummary(count: content.next.count, playableSeconds: content.playableSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.xs)
            Button(QueuePanelWords.clear) {
                QueueEditCommands.perform({ $0.clearNext() }, playback: playback, undo: undo)
            }
            .buttonStyle(.borderless)
            .disabled(content.isNextEmpty)
            .help(optional: content.isNextEmpty ? QueuePanelWords.clearDisabledHelp : nil)
        }
    }

    /// `From “Warm-up”` — a link to the list it plays from while that list exists (the one
    /// navigation the panel offers, like ⌘L), else plain text.
    @ViewBuilder
    private func contextDivider(_ content: QueuePanelContent) -> some View {
        let title = QueuePanelWords.contextHeader(content.contextName)
        if content.origin != nil, content.contextName != nil {
            Button(title) { goToContext() }
                .buttonStyle(.link)
                .font(.subheadline)
                .lineLimit(1)
                .help("Show \(content.contextName ?? "")")
        } else {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Chrome

    private func driveLine(_ volumeName: String) -> some View {
        Label {
            Text(QueuePanelWords.driveAway(volumeName))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func footer(_ content: QueuePanelContent) -> some View {
        let tracks = content.tracksToSave
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Button(QueuePanelWords.saveAsPlaylist) { showsSave = true }
                .disabled(tracks.isEmpty)
                .help(optional: tracks.isEmpty ? QueuePanelWords.saveDisabledHelp : nil)
                .popover(isPresented: $showsSave, arrowEdge: .top) {
                    SaveQueueAsPlaylistPopover(trackCount: ShellEdits.uniqued(tracks.compactMap(\.id)).count) { name in
                        showsSave = false
                        Task { await QueueEditCommands.saveAsPlaylist(name: name, tracks: tracks, undo: undo, container: container) }
                    } cancel: {
                        showsSave = false
                    }
                }
            Text(QueuePanelWords.keptNote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Actions

    private var validatedOrigin: PlaybackOrigin? {
        guard let origin = playback.playingOrigin else { return nil }
        let checked = GoToCurrentTrack.validated(origin)
        return checked == origin ? origin : nil
    }

    private func goToContext() {
        guard let origin = validatedOrigin, let navigation else { return }
        if playback.currentTrack != nil {
            GoToCurrentTrack.perform(playback: playback, navigation: navigation, search: search)
            return
        }
        if navigation.selection != origin.place { navigation.select(origin.place) }
        if navigation.path != origin.path { navigation.setPath(origin.path) }
    }

    /// Return / double-click: the first selected row in display order plays (UC-PRIM-12).
    private func play(_ ids: Set<UUID>, content: QueuePanelContent) {
        guard let row = content.rows(ids).first else { return }
        let preview = playback.preview
        if preview.isActive {
            // Return while previewing plays the previewed track from where the preview is.
            preview.handOver(row.track)
        }
        Task { await playback.playQueueEntry(row.id) }
    }

    private func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        QueueEditCommands.perform({ $0.removeEntries(Set(ids)) }, playback: playback, undo: undo)
    }

    private func previewKey(_ press: KeyPress, content: QueuePanelContent, live: TrackTableLiveState) -> KeyPress.Result {
        let key: TrackListPreviewKey.Key
        switch press.key {
        case .space: key = .space
        case .leftArrow: key = .leftArrow
        case .rightArrow: key = .rightArrow
        default: return .ignored
        }
        let preview = playback.preview
        let decision = TrackListPreviewKey.decide(
            key: key,
            isRepeat: press.phase == .repeat,
            hasCommandModifiers: !press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
            isPreviewing: preview.isActive,
            secondsSinceTypeSelect: typeSelect.last.map { Date().timeIntervalSince($0) }
        )
        switch decision {
        case .togglePreview:
            typeSelect.last = nil
            let rows = content.rows(selection)
            // Space on the playing row does nothing: it is already playing.
            if !preview.isActive, rows.count == 1, rows[0].place == .nowPlaying { return .handled }
            preview.toggle(owner: Self.previewOwner, candidate: previewCandidate(rows, live: live))
            return .handled
        case .endPreview:
            preview.escape()
            return .handled
        case .seek(let delta):
            preview.seek(by: delta)
            return .handled
        case .swallow:
            return .handled
        case .passOn:
            return .ignored
        }
    }

    /// What Space previews: the selected row — never the playing row itself.
    private func previewCandidate(_ rows: [QueuePanelRow], live: TrackTableLiveState) -> PreviewCandidate {
        if rows.count == 1, rows[0].place == .nowPlaying { return .nothing }
        return PreviewCandidate.make(rows: rows.map(\.row), live: live)
    }

    // MARK: Menu (CM-QUEUE)

    @ViewBuilder
    private func menu(for ids: Set<UUID>, content: QueuePanelContent, live: TrackTableLiveState) -> some View {
        let subject = content.rows(ids)
        if !subject.isEmpty {
            let context = TrackMenuContext(
                container: .queue, canActivate: true, canRemoveFromContainer: true, canAddToSyncProfile: true,
                canPreview: true, canLocate: true, queueRows: content.menuRows(for: subject)
            )
            let model = TrackMenuModel.make(subject: TrackMenuSubject(rows: subject.map(\.row), live: live), context: context)
            let sources = TrackMenuSources.shared
            TrackMenu(
                model: model,
                rows: subject.map(\.row),
                actions: menuActions(subject, content: content, live: live),
                playlists: sources.playlists,
                syncProfiles: sources.syncProfiles,
                offlineVolumeName: live.offlineVolumeName
            )
        }
    }

    private func menuActions(_ subject: [QueuePanelRow], content: QueuePanelContent, live: TrackTableLiveState) -> QueuePanelMenuActions {
        QueuePanelMenuActions(
            subject: subject,
            playback: playback,
            undo: undo,
            origin: validatedOrigin,
            tracks: TrackListActions(model: TrackListModel(), configuration: .queue(section: "panel", accessibilityID: "queue_panel", activate: nil),
                                     live: TrackTableLive(state: live), statusBar: statusBar, undo: undoCenter, shell: shell,
                                     container: container, navigation: navigation),
            play: { play(Set(subject.map(\.id)), content: content) },
            preview: {
                playback.preview.toggle(owner: Self.previewOwner, candidate: previewCandidate(subject, live: live))
            },
            navigation: navigation
        )
    }

    // MARK: Track menu (UC-SEL-02)

    /// The selection as the menu bar sees it: Track ▸ Play plays the row, Play Next / Add to
    /// Queue / Add to Playlist act on its tracks, Remove from Queue on its Next rows; never
    /// the irreversible library removal (UC-CM-07).
    private func trackSelection(content: QueuePanelContent, live: TrackTableLiveState) -> TrackSelection? {
        let subject = content.rows(selection)
        guard !subject.isEmpty else { return nil }
        let sources = TrackMenuSources.shared
        let actions = menuActions(subject, content: content, live: live)
        let nextIDs = subject.filter(\.isInNext).map(\.id)
        var hasher = Hasher()
        subject.forEach { hasher.combine($0.id) }
        let tracks = subject.map(\.track)
        return TrackSelection(
            selectedIDs: Set(subject.map(\.row.id)),
            summary: TrackSelectionSummary(rows: subject.map(\.row), container: .queue, live: live),
            context: .queue,
            hasPlayableRows: false,
            rowsToken: hasher.finalize(),
            target: TrackCommandTarget(
                activate: { _, _ in play(Set(subject.map(\.id)), content: content) },
                removeFromContainer: nextIDs.isEmpty ? nil : { _ in remove(nextIDs) },
                deselectAll: { selection = [] },
                playlists: sources.playlists,
                syncProfiles: sources.syncProfiles,
                addToSyncProfile: { profile, _ in actions.addToSyncProfile(profile, subject.map(\.row)) },
                preview: { actions.preview(nil) },
                recordOrigin: nil,
                playNext: { actions.playNext(subject.map(\.row)) },
                addToQueueDisabledReason: nextIDs.isEmpty ? nil : QueueWords.alreadyQueuedReason
            ),
            rows: { tracks }
        )
    }

    // MARK: Drag

    /// A row drags as its track (playlists, the sidebar) and, inside the panel, as its entry.
    static func provider(for item: QueuePanelRow) -> NSItemProvider {
        let provider = NSItemProvider()
        // W2-H: the shared track payload (ids + the entry + the local file, UC-DND-01).
        let context = MainActor.assumeIsolated { TrackDragContext.current(.shared) }
        provider.register(context.item(for: item.row.track, availability: item.row.availability, queueEntryID: item.id)
            ?? TrackDragItem(trackId: item.row.id, queueEntryId: item.id, libraryId: nil))
        return provider
    }
}

// MARK: - Rows

/// One queue row (UC-TRAIL-05): cover, title, artist, time; the state word only when the row
/// can't play now. Now playing is a little larger with the now-playing glyph.
private struct QueueRowView: View {
    let item: QueuePanelRow
    let live: TrackTableLiveState
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cover sizes: rows like the toolbar player's cover, Now playing larger (`queue.html`).
    static let coverSize: CGFloat = 28
    static let nowPlayingCoverSize: CGFloat = 40

    var body: some View {
        let presentation = TrackRowPresentation(row: item.row, live: live)
        let isNow = item.place == .nowPlaying
        let dimmed = presentation.isDimmed
        HStack(spacing: Spacing.s) {
            artwork(presentation)
                .frame(width: isNow ? Self.nowPlayingCoverSize : Self.coverSize,
                       height: isNow ? Self.nowPlayingCoverSize : Self.coverSize)
                .opacity(dimmed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.xxs) {
                    if isNow {
                        Image(systemName: "speaker.wave.2.fill")
                            .imageScale(.small)
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                            .accessibilityHidden(true)
                    }
                    Text(item.row.title)
                        .fontWeight(isNow ? .semibold : nil)
                        .lineLimit(1)
                        .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                }
                HStack(spacing: Spacing.xxs) {
                    Text(item.row.artistText ?? "—")
                        .lineLimit(1)
                    if let status = presentation.status {
                        Text("·")
                        TrackStatusLabel(status: status)
                            .help(optional: item.row.failureDetail)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: Spacing.xs)
            if let time = item.row.timeText {
                Text(time)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
        }
        .typeSelectEquivalent(item.row.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(presentation, isNow: isNow))
    }

    @ViewBuilder
    private func artwork(_ presentation: TrackRowPresentation) -> some View {
        if presentation.showsPlaceholderArtwork {
            TrackPlaceholderArtwork()
        } else {
            TrackCoverView(trackId: item.row.id, size: .small, cornerRadius: 4)
        }
    }

    /// Title, artist, the state word; `Now playing`; why it is dimmed (UC-A11Y-07).
    private func accessibilityText(_ presentation: TrackRowPresentation, isNow: Bool) -> String {
        var parts = [item.row.title, item.row.artistText ?? "Unknown artist"]
        if let status = presentation.status { parts.append(status.text) }
        if isNow { parts.append("Now playing") }
        if presentation.isDimmed, let name = live.offlineVolumeName {
            parts.append("Not reachable — “\(name)” is not connected")
        }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    /// The reason as help text on a disabled control; nothing on an enabled one.
    @ViewBuilder
    func help(optional reason: String?) -> some View {
        if let reason { help(reason) } else { self }
    }
}

/// The one sentence inside an empty section (UC-EMPTY-03, V-QUEUE.E04).
private struct QueueEmptyText: View {
    let title: String?
    let sentence: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let title {
                Text(title).fontWeight(.semibold)
            }
            if let sentence {
                Text(sentence)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .selectionDisabled()
    }
}

// MARK: - Menu actions

/// What the queue's menu items do: queue edits act on the subject's entries (never on "all
/// rows of this track"); the shared items (Add to Playlist, Get Info, Download, Show in
/// Finder, Copy) are the track tables' own.
@MainActor
struct QueuePanelMenuActions: TrackMenuActions {
    let subject: [QueuePanelRow]
    let playback: PlaybackViewModel
    let undo: UndoCenter
    let origin: PlaybackOrigin?
    /// The track tables' actions for the shared items.
    let tracks: TrackListActions
    let playAction: () -> Void
    let previewToggle: () -> Void
    let navigation: NavigationModel?

    init(subject: [QueuePanelRow], playback: PlaybackViewModel, undo: UndoCenter, origin: PlaybackOrigin?,
         tracks: TrackListActions, play: @escaping () -> Void, preview: @escaping () -> Void, navigation: NavigationModel?) {
        self.subject = subject
        self.playback = playback
        self.undo = undo
        self.origin = origin
        self.tracks = tracks
        self.playAction = play
        self.previewToggle = preview
        self.navigation = navigation
    }

    private var nextIDs: [UUID] { subject.filter(\.isInNext).map(\.id) }

    func play(_ rows: [TrackRow]) { playAction() }
    func preview(_ rows: [TrackRow]?) { previewToggle() }

    /// Next rows move to the top; History / Now playing rows are queued again at the top.
    func playNext(_ rows: [TrackRow]) {
        let ids = nextIDs
        if ids.isEmpty {
            QueueEditCommands.queue(subject.map(\.track), as: .playNext, playback: playback, undo: undo)
        } else {
            QueueEditCommands.perform({ $0.moveEntriesToTop(ids) }, playback: playback, undo: undo)
        }
    }

    func addToQueue(_ rows: [TrackRow]) {
        QueueEditCommands.queue(subject.map(\.track), as: .addToQueue, playback: playback, undo: undo)
    }

    func moveToEndOfQueue(_ rows: [TrackRow]) {
        let ids = nextIDs
        guard !ids.isEmpty else { return }
        QueueEditCommands.perform({ $0.moveEntriesToEnd(ids) }, playback: playback, undo: undo)
    }

    func removeFromContainer(_ rows: [TrackRow]) {
        let ids = Set(nextIDs)
        guard !ids.isEmpty else { return }
        QueueEditCommands.perform({ $0.removeEntries(ids) }, playback: playback, undo: undo)
    }

    func clearHistory() {
        QueueEditCommands.perform({ $0.clearHistory() }, playback: playback, undo: undo)
    }

    /// `Show in “‹context›”`: the row in the list it plays from (navigates, like ⌘L).
    func showInContext(_ rows: [TrackRow]) {
        guard let origin, let navigation, let row = subject.first else { return }
        if navigation.selection != origin.place { navigation.select(origin.place) }
        if navigation.path != origin.path { navigation.setPath(origin.path) }
        if origin.place == .allTracks, origin.path.isEmpty {
            DependencyContainer.shared.libraryViewModel?.reveal(trackID: row.row.id, availability: row.track.availability())
        }
        TrackListReveal.shared.reveal(trackID: row.row.id, title: row.row.title, listKey: origin.listKey, container: origin.container)
    }

    func addToPlaylist(_ playlistID: Int64, _ rows: [TrackRow]) { tracks.addToPlaylist(playlistID, rows) }
    func newPlaylist(_ rows: [TrackRow]) { tracks.newPlaylist(rows) }
    func addToSyncProfile(_ profile: SyncProfile, _ rows: [TrackRow]) { tracks.addToSyncProfile(profile, rows) }
    func newSyncProfile(_ rows: [TrackRow]) { tracks.newSyncProfile(rows) }
    func getInfo(_ rows: [TrackRow]) { tracks.getInfo(rows) }
    func goToAlbum(_ albumID: Int64) { navigation?.push(.album(albumID)) }
    func findSimilar(_ rows: [TrackRow]) { tracks.findSimilar(rows) }
    func download(_ rows: [TrackRow]) { tracks.download(rows) }
    func downloadAgain(_ rows: [TrackRow]) { tracks.downloadAgain(rows) }
    func locateFile(_ rows: [TrackRow]) { tracks.locateFile(rows) }
    func showInFinder(_ rows: [TrackRow]) { tracks.showInFinder(rows) }
    func copyTitleAndArtist(_ rows: [TrackRow]) { tracks.copyTitleAndArtist(rows) }
    func copyFilePaths(_ rows: [TrackRow]) { tracks.copyFilePaths(rows) }
    func copyLinks(_ rows: [TrackRow]) { tracks.copyLinks(rows) }
    func removeFromLibrary(_ rows: [TrackRow]) {
        // Not offered in the queue (UC-CM-07): the queue is a play order, not a place to delete music.
    }
}
