import Foundation
import Testing
@testable import MLM

/// W2-D: what the Queue panel shows (P-QUEUE, UC-TRAIL-05), its safe menu (CM-QUEUE), the
/// commands wired everywhere, and its structure (native List, no theme tokens, no disk probes).
@Suite("QueuePanelTests")
@MainActor
struct QueuePanelTests {
    private func track(_ id: Int64, path: String? = "A/x.m4a", duration: Int = 200, failed: Bool = false) -> Track {
        var t = Track(artist: "Artist \(id)", album: "Album", title: "T\(id)", format: "m4a", originalPath: "https://soundcloud.com/a/\(id)")
        t.id = id
        t.organizedPath = path
        t.duration = duration
        if failed { t.downloadStatus = "failed" }
        return t
    }

    private let offline = TrackTableLiveState(offlineVolumePath: "/Volumes/Lexxar", offlineVolumeName: "Lexxar")

    private func content(pn: [Track] = [], ctx: [Track] = [], history: [QueueEntry] = [], current: QueueEntry? = nil,
                         origin: PlaybackOrigin? = nil, live: TrackTableLiveState = .idle) -> QueuePanelContent {
        QueuePanelContent.make(
            current: current?.track, currentEntryID: current?.id,
            queue: PlaybackQueue(playNext: pn.map { QueueEntry(track: $0) }, context: ctx.map { QueueEntry(track: $0) }),
            history: history + (current.map { [$0] } ?? []), origin: origin, live: live)
    }

    // MARK: Sections

    @Test func threeSectionsWithHistoryMostRecentFirstAndWithoutThePlayingEntry() {
        let older = QueueEntry(track: track(1)), newer = QueueEntry(track: track(2))
        let now = QueueEntry(track: track(3))
        let c = content(pn: [track(4)], ctx: [track(5), track(6)], history: [older, newer], current: now)
        #expect(c.nowPlaying?.id == now.id)
        #expect(c.history.map(\.id) == [newer.id, older.id])
        #expect(c.next.map(\.track.id) == [4, 5, 6])
        #expect(c.nextItems.count == 4, "Play Next item, divider, two context rows")
        #expect(c.nextItems[1] == .divider)
        #expect(c.tracksToSave.map(\.id) == [3, 4, 5, 6], "Now playing + Next, in queue order")
    }

    @Test func emptyNextHasItsSentenceAndDropsGoToTheTop() {
        let c = content()
        #expect(c.nextItems == [.empty])
        #expect(c.position(forDropAt: 1) == .top)
        #expect(c.isEmpty)
        #expect(c.tracksToSave.isEmpty)
    }

    @Test func dropPositionsFollowTheDivider() {
        let c = content(pn: [track(1)], ctx: [track(2), track(3)])
        #expect(c.position(forDropAt: 0) == .top)
        #expect(c.position(forDropAt: 1) == QueuePosition(lane: .playNext, index: 1))
        #expect(c.position(forDropAt: 2) == QueuePosition(lane: .context, index: 0))
        #expect(c.position(forDropAt: 4) == QueuePosition(lane: .context, index: 2))
    }

    @Test func timeLeftCountsOnlyWhatCanPlayNow() {
        let c = content(ctx: [track(1, duration: 100), track(2, path: nil, duration: 300), track(3, duration: 60)])
        #expect(c.playableSeconds == 160)
        #expect(QueuePanelWords.nextSummary(count: 3, playableSeconds: 160) == "3 tracks · 3 min")
        let away = content(ctx: [track(1, duration: 100)], live: offline)
        #expect(away.playableSeconds == 0, "nothing on the disk that is away can play now")
    }

    @Test func theSameTrackTwiceIsTwoRows() {
        let c = content(pn: [track(1)], ctx: [track(1)])
        #expect(c.next.count == 2)
        #expect(Set(c.next.map(\.id)).count == 2)
        #expect(Set(c.nextItems.map(\.id)).count == 3)
    }

    @Test func contextHeaderNamesTheList() {
        let playlist = PlaybackOrigin(place: .playlist(7), path: [], listKey: "playlist", container: .playlist(id: 7, name: "Warm-up"))
        #expect(QueuePanelWords.contextHeader(content(ctx: [track(1)], origin: playlist).contextName) == "From “Warm-up”")
        #expect(QueuePanelWords.contextHeader(content(ctx: [track(1)], origin: .allTracks).contextName) == "From All Tracks")
        #expect(QueuePanelWords.contextHeader(nil) == "From the played list")
    }

    @Test func stateWordsOnlyForRowsThatCantPlay() {
        let c = content(ctx: [track(1), track(2, path: nil), track(3, path: nil, failed: true)])
        let words = c.next.map { TrackRowPresentation(row: $0.row, live: .idle).status?.text }
        #expect(words == [nil, "Not downloaded", "Download failed"])
        // The disk is away: local rows are dimmed without a word (the line above speaks);
        // not-downloaded rows keep theirs.
        let away = content(ctx: [track(1), track(2, path: nil)], live: offline)
        let presentations = away.next.map { TrackRowPresentation(row: $0.row, live: offline) }
        #expect(presentations[0].isDimmed && presentations[0].status == nil)
        #expect(!presentations[1].isDimmed && presentations[1].status?.text == "Not downloaded")
    }

    // MARK: CM-QUEUE

    private func queueMenu(_ c: QueuePanelContent, _ subject: [QueuePanelRow], live: TrackTableLiveState = .idle) -> TrackMenuModel {
        let context = TrackMenuContext(container: .queue, canActivate: true, canRemoveFromContainer: true,
                                       canAddToSyncProfile: true, queueRows: c.menuRows(for: subject))
        return TrackMenuModel.make(subject: TrackMenuSubject(rows: subject.map(\.row), live: live), context: context)
    }

    @Test func nextRowMenuFollowsTheCatalogue() {
        let c = content(ctx: [track(1)], origin: PlaybackOrigin(place: .playlist(7), path: [], listKey: "playlist",
                                                               container: .playlist(id: 7, name: "Warm-up")))
        let model = queueMenu(c, c.next)
        #expect(model.sections == [
            [.play(enabled: true), .preview(enabled: true)],
            [.playNext, .moveToEndOfQueue],
            [.addToPlaylist, .addToSyncProfile],
            [.getInfo, .goToArtist("Artist 1"), .showInContext(name: "“Warm-up”")],
            [.showInFinder(enabled: true), .copy(filePath: true, link: true)],
            [.removeFromContainer(title: "Remove from Queue")],
        ])
        #expect(!model.items.contains(.addToQueue), "rows already in the queue have no Add to Queue")
        #expect(!model.items.contains { if case .removeFromLibrary = $0 { true } else { false } })
    }

    @Test func notDownloadedNextRowOffersDownload() {
        let c = content(pn: [track(1, path: nil)])
        let items = queueMenu(c, c.next).items
        #expect(items.contains(.download(title: "Download")))
        #expect(!items.contains { if case .showInContext = $0 { true } else { false } }, "a Play Next row has no context")
        #expect(items.last == .removeFromContainer(title: "Remove from Queue"))
    }

    @Test func historyAndNowPlayingMenusEndWithClearHistory() {
        let past = QueueEntry(track: track(1)), now = QueueEntry(track: track(2))
        let c = content(history: [past], current: now)
        let history = queueMenu(c, c.history)
        #expect(history.sections == [
            [.play(enabled: true)],
            [.playNext, .addToQueue],
            [.addToPlaylist, .addToSyncProfile],
            [.getInfo],
            [.showInFinder(enabled: true), .copy(filePath: true, link: true)],
            [.clearHistory],
        ])
        let playing = queueMenu(c, [c.nowPlaying!])
        #expect(!playing.items.contains(.play(enabled: true)), "the playing row isn't played again")
        #expect(playing.items.last == .clearHistory)
        // Several rows: the count header first; a Next row in it makes it the Next menu.
        let mixed = queueMenu(c, [c.nowPlaying!, c.history[0]])
        #expect(mixed.sections.first == [.countHeader(2)])
    }

    @Test func everyTrackListOffersAddToQueue() {
        let library = TrackMenuContext(container: .library, canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)
        let model = TrackMenuModel.make(subject: TrackMenuSubject(rows: TrackRowBuilder.build([track(1)]), live: .idle), context: library)
        #expect(model.sections[1] == [.playNext, .addToQueue])
    }

    // MARK: Words

    @Test func sentencesAreTheDesignedOnes() {
        #expect(QueuePanelWords.driveAway("Lexxar") == "“Lexxar” is not connected. The queue is kept; playback continues when “Lexxar” is back.")
        #expect(QueuePanelWords.created(name: "Queue — 5 Oct 2026", count: 12) == "Created playlist “Queue — 5 Oct 2026” with 12 tracks")
        #expect(QueuePanelWords.saveCount(1) == "1 track, in queue order")
        #expect(QueuePanelWords.defaultPlaylistName(date: Date(timeIntervalSince1970: 0)).hasPrefix("Queue — "))
        #expect(QueueWords.leftOutSuffix(1) == " · 1 isn’t downloaded and was left out")
        #expect(QueueWords.nothingToQueue(count: 3) == "Nothing to queue — the 3 tracks aren’t downloaded")
        for text in [QueuePanelWords.queueEmptySentence, QueuePanelWords.keptNote, QueuePanelWords.noHistory,
                     QueuePanelWords.unavailableSentence, QueuePanelWords.clearDisabledHelp, QueuePanelWords.saveDisabledHelp] {
            #expect(text.hasSuffix("."), "\(text) is a sentence (UC-COPY-04)")
            #expect(!text.contains("'") && !text.contains("\""), "typographic quotes only (UC-COPY-06)")
        }
    }

    // MARK: Drag payload

    @Test func aQueueRowDragsAsATrackForEveryTrackDropTarget() throws {
        let entry = UUID()
        let data = try JSONEncoder().encode(QueueRowDrag(trackId: 4, sourcePlaylistId: nil, queueEntryId: entry))
        let asTrack = try JSONDecoder().decode(TrackDragData.self, from: data)
        #expect(asTrack.trackId == 4 && asTrack.sourcePlaylistId == nil)
        let fromTable = try JSONEncoder().encode(TrackDragData(trackId: 9, sourcePlaylistId: 2))
        let asDrop = try JSONDecoder().decode(QueueRowDrag.self, from: fromTable)
        #expect(asDrop.trackId == 9 && asDrop.queueEntryId == nil)
    }

    // MARK: Commands everywhere

    @Test func addToQueueIsWiredWithItsKeyAndShownInTheKeyboardMap() {
        #expect(!MenuCommand.addToQueue.isPending)
        #expect(MenuCommand.addToQueue.shortcut == MenuShortcut(key: .returnKey, modifiers: [.option, .shift]))
        let rows = KeyboardMap.visibleGroups.flatMap(\.rows)
        #expect(rows.contains { $0.command == .addToQueue })
        #expect(MenuCommand.allCases.compactMap(\.pendingOwner).allSatisfy { $0 != "W2-D" }, "nothing left pending for W2-D")
    }

    // MARK: Structure

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func thePanelIsANativeListWithoutThemeTokensGlassOrDiskProbes() throws {
        for path in ["MLM/Views/Queue/QueuePanel.swift", "MLM/Views/Queue/QueuePanelModel.swift",
                     "MLM/Views/Queue/QueueEditCommands.swift", "MLM/Views/Queue/SaveQueueAsPlaylistPopover.swift"] {
            let text = try source(path)
            #expect(!text.contains(".mlm") && !text.contains("MLMFont"), "\(path) uses a deprecated theme token")
            #expect(!text.contains("glassEffect") && !text.contains("Material"), "\(path): no glass or material on the panel")
            #expect(!text.contains("fileExists"), "\(path) probes the disk")
            #expect(!text.contains("#available"))
            #expect(!text.contains("Remove from Library"), "\(path): the queue's menu is safe (UC-CM-07)")
            #expect(!text.contains("confirmationDialog") && !text.contains(".alert("), "no confirmation alerts (DEC-050)")
        }
        let panel = try source("MLM/Views/Queue/QueuePanel.swift")
        #expect(panel.contains("List(selection: $selection)"))
        #expect(panel.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(panel.contains(".onDeleteCommand"))
        #expect(!panel.contains("TrackSelectionBar"), "no selection bar in the queue (UC-SELBAR-05)")
        #expect(!panel.contains("trailingColumn") && !panel.contains(".toggle(.queue)"), "it never opens itself")
        #expect(try source("MLM/Views/Shell/TrailingColumnView.swift").contains("QueuePanel()"))
        #expect(try source("MLM/Views/Player/PlayerBar.swift").contains("QueueEditCommands.dropOnPlayer"))
        let commands = try source("MLM/App/Commands/TrackCommands.swift")
        #expect(commands.contains("TrackCommandActions.addToQueue("))
        #expect(commands.contains("TrackCommandActions.playNext(tracks(), undo: undoCenter)"))
    }
}
