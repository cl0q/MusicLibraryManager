import Foundation
import GRDB
import Testing
@testable import MLM

/// W2-D review round: Repeat All follows queue edits (S1), undo never brings back what is gone
/// (S2, S3, S4), Move to End (S5), mixed drops (S6), Previous's track belongs to the context
/// (S7), Return after a preview of the playing row (S8), one route for Play Next and Add to
/// Queue (S9), the delete cascade (S10), and the nits.
@Suite("QueueReviewFixTests")
@MainActor
struct QueueReviewFixTests {
    struct Rig {
        let vm: PlaybackViewModel
        let main: SilentAudioPlayer
        let preview: SilentAudioPlayer
        let env: PlaybackTestEnvironment
        let folder: PlaybackFixtureFolder
    }

    private func rig() -> Rig {
        let folder = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment()
        let main = SilentAudioPlayer()
        let preview = SilentAudioPlayer()
        let vm = PlaybackViewModel(audioPlayer: main, environment: env.environment, previewPlayer: { preview },
                                   previewSchedule: { _, _ in })
        return Rig(vm: vm, main: main, preview: preview, env: env, folder: folder)
    }

    private func local(_ id: Int64, _ rig: Rig) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = rig.folder.file("\(id).m4a")
        t.duration = 200
        return t
    }

    private func track(_ id: Int64) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = "A/\(id).m4a"
        return t
    }

    private func nextIDs(_ vm: PlaybackViewModel) -> [Int64?] { vm.queueSnapshot.upcoming.map(\.id) }

    // MARK: S1 — Repeat All follows the context

    @Test func theRepeatPassFollowsContextEdits() throws {
        var q = PlaybackQueue()
        q.startContext(track(1), following: [track(2), track(3), track(4)], cap: 100)
        let c = q.contextEntries
        // Remove 3: the next pass hasn't it either.
        let removed = try #require(QueueEditing.remove([c[1].id], queue: q, history: []))
        #expect(removed.queue.cycle.map(\.id) == [1, 2, 4])
        // Move 4 before 2 within the context: the pass moves too.
        let moved = try #require(QueueEditing.move([c[2].id], to: QueuePosition(lane: .context, index: 0), queue: q, history: []))
        #expect(moved.queue.cycle.map(\.id) == [1, 4, 2, 3])
        // Added into the context: it joins; moved up into Play Next: it leaves.
        let added = try #require(QueueEditing.insert([track(9)], at: QueuePosition(lane: .context, index: 3), queue: q, history: []))
        #expect(added.queue.cycle.map(\.id) == [1, 2, 3, 4, 9])
        let up = try #require(QueueEditing.moveToTop([c[0].id], queue: q, history: []))
        #expect(up.queue.cycle.map(\.id) == [1, 3, 4])
        // Play Next items never join.
        let pn = try #require(QueueEditing.playNext([track(8)], queue: q, history: []))
        #expect(pn.queue.cycle.map(\.id) == [1, 2, 3, 4])
        // Undo puts it back in the pass.
        let undone = QueueEditing.revert(removed.receipt, queue: removed.queue, history: [], historyCap: 50)
        #expect(undone.queue.cycle.map(\.id) == [1, 2, 3, 4])
    }

    @Test func aRemovedTrackIsNotReplayedWithRepeatAll() async {
        let r = rig()
        r.vm.setRepeatMode(.all)
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        r.vm.removeEntries([r.vm.queueSnapshot.contextEntries[0].id])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 3)
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 1, "the pass starts again")
        #expect(nextIDs(r.vm) == [3], "without the removed track")
    }

    @Test func playbackStopsAfterThisTrackOnlyWithoutARepeatPass() {
        var q = PlaybackQueue()
        q.startContext(track(1), following: [], cap: 100)
        let now = QueueEntry(track: track(1))
        func content(_ repeatsAll: Bool) -> QueuePanelContent {
            QueuePanelContent.make(current: now.track, currentEntryID: now.id, queue: q, history: [now], origin: nil,
                                   live: .idle, repeatsAll: repeatsAll)
        }
        #expect(content(false).playbackStopsAfterCurrent)
        #expect(!content(true).playbackStopsAfterCurrent, "Repeat All plays the pass again")
        let cleared = QueueEditing.clearNext(queue: q, history: [])!.queue
        let afterClear = QueuePanelContent.make(current: now.track, currentEntryID: now.id, queue: cleared, history: [now],
                                                origin: nil, live: .idle, repeatsAll: true)
        #expect(afterClear.playbackStopsAfterCurrent, "Clear empties the pass")
    }

    // MARK: S2 — tracks removed from the library never come back

    @Test func undoAndRedoNeverBringBackDeletedTracks() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), x = local(9, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        // Undo Remove.
        let removed = r.vm.removeEntries([r.vm.queueSnapshot.contextEntries[0].id])!
        await r.vm.removeTracksFromQueue([2])
        #expect(!r.vm.revertQueueEdit(removed), "nothing left to undo")
        #expect(nextIDs(r.vm) == [3])
        // Undo Clear: only what still exists comes back.
        let cleared = r.vm.clearNext()!
        await r.vm.removeTracksFromQueue([3])
        #expect(!r.vm.revertQueueEdit(cleared))
        #expect(r.vm.queueSnapshot.cycle.allSatisfy { $0.id != 3 && $0.id != 2 })
        // Undo Clear History.
        await r.vm.playTrack(b)
        let history = r.vm.clearHistory()!
        await r.vm.removeTracksFromQueue([1])
        #expect(!r.vm.revertQueueEdit(history), "the only removed History entry was track 1")
        #expect(!r.vm.history.contains { $0.id == 1 })
        // Redo Add to Queue.
        let addedX = r.vm.addToQueue([x])!
        #expect(r.vm.revertQueueEdit(addedX))
        await r.vm.removeTracksFromQueue([9])
        #expect(!r.vm.reapplyQueueEdit(addedX))
        #expect(!nextIDs(r.vm).contains(9))
    }

    // MARK: S3 — one entry, one place

    @Test func redoNeverPutsThePlayingEntryBackIntoNext() async {
        let r = rig()
        let a = local(1, r), x = local(8, r), y = local(9, r)
        await r.vm.playTrack(a)
        let added = r.vm.addToQueue([x, y])!
        let e1 = r.vm.queueSnapshot.playNextEntries[0].id
        await r.vm.playQueueEntry(e1)
        #expect(r.vm.currentEntryID == e1)
        #expect(r.vm.revertQueueEdit(added), "undo takes out the entry still queued (y)")
        #expect(nextIDs(r.vm).isEmpty)
        #expect(r.vm.reapplyQueueEdit(added))
        #expect(nextIDs(r.vm) == [9], "the playing entry is not queued again")
        let ids = r.vm.queueSnapshot.upcomingEntries.map(\.id) + r.vm.historyEntries.map(\.id)
        #expect(Set(ids).count == ids.count, "no id in two places")
    }

    // MARK: S4 — undo never mixes contexts

    @Test func undoAfterANewContextLeavesTheOldContextOut() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), p = local(7, r), x = local(8, r), y = local(9, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        let removedContext = r.vm.removeEntries([r.vm.queueSnapshot.contextEntries[1].id])!
        r.vm.playNext([p])
        let removedPlayNext = r.vm.removeEntries([r.vm.queueSnapshot.playNextEntries[0].id])!
        await r.vm.playTrack(x, queue: [x, y])
        #expect(nextIDs(r.vm) == [9])
        #expect(!r.vm.revertQueueEdit(removedContext), "3 belonged to the old context")
        #expect(nextIDs(r.vm) == [9])
        #expect(r.vm.revertQueueEdit(removedPlayNext), "a Play Next item survives context switches")
        #expect(nextIDs(r.vm) == [7, 9])
    }

    // MARK: S5 — Move to End

    @Test func moveToEndOfEverythingIsNoStepAndContextStaysContext() throws {
        var q = PlaybackQueue()
        q.startContext(track(1), following: [track(2), track(3)], cap: 100)
        let withPlayNext = try #require(QueueEditing.playNext([track(9)], queue: q, history: [])).queue
        let all = withPlayNext.upcomingEntries.map(\.id)
        #expect(QueueEditing.moveToEnd(all, queue: withPlayNext, history: []) == nil, "already the end, in order")
        let two = withPlayNext.contextEntries[0].id
        let moved = try #require(QueueEditing.moveToEnd([two], queue: withPlayNext, history: []))
        #expect(moved.queue.playNext.map(\.id) == [9])
        #expect(moved.queue.context.map(\.id) == [3, 2], "it stays a context entry")
        #expect(moved.queue.cycle.map(\.id) == [1, 3, 2], "and the pass follows")
    }

    // MARK: S6 — mixed drops

    @Test func droppingNextRowsWithHistoryRowsIsOneStepWithoutDuplicates() async throws {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), d = local(4, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        let undo = UndoCenter(statusBar: StatusBarCenter())
        let three = r.vm.queueSnapshot.contextEntries[1]
        let past = r.vm.historyEntries[0]  // a (playing) — its row dragged as a track
        let items = [QueueRowDrag(trackId: 3, queueEntryId: three.id), QueueRowDrag(trackId: 1, queueEntryId: past.id)]
        let task = QueueEditCommands.drop(items, at: QueueDropTarget.position(.top), playback: r.vm, undo: undo,
                                          tracks: { ids in ids.compactMap { [1: a, 3: c][$0] } })
        await task?.value
        #expect(nextIDs(r.vm) == [3, 1, 2, 4], "3 moved, 1 added after it — 3 not duplicated")
        #expect(r.vm.queueSnapshot.playNextEntries[0].id == three.id)
        #expect(undo.stepCount == 1, "one gesture, one step")
    }

    @Test func aDropTargetIsResolvedAgainstTheQueueWhenItApplies() {
        var q = PlaybackQueue()
        q.startContext(track(1), following: [track(2), track(3)], cap: 100)
        let three = q.contextEntries[1].id
        let target = QueueDropTarget.before(three, fallback: .top)
        #expect(target.resolve(in: q) == QueuePosition(lane: .context, index: 1))
        // The list changed after it was drawn: the line still sits above 3.
        let edited = QueueEditing.remove([q.contextEntries[0].id], queue: q, history: [])!.queue
        #expect(target.resolve(in: edited) == QueuePosition(lane: .context, index: 0))
        #expect(QueueDropTarget.end.resolve(in: edited) == QueuePosition(lane: .context, index: 1))
        #expect(QueueDropTarget.endOfPlayNext.resolve(in: edited) == .top)
        // The panel names targets by the row below the line.
        let content = QueuePanelContent.make(current: nil, currentEntryID: nil, queue: q, history: [], origin: nil, live: .idle)
        #expect(content.dropTarget(forDropAt: 0) == .endOfPlayNext, "the line on the divider")
        #expect(content.dropTarget(forDropAt: 2) == .before(three, fallback: QueuePosition(lane: .context, index: 1)))
        #expect(content.dropTarget(forDropAt: 3) == .end)
    }

    // MARK: S7 — Previous's track belongs to the context

    @Test func theTrackLeftByPreviousPlaysFirstButLeavesWithItsContext() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), p = local(7, r), x = local(8, r), y = local(9, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        await r.vm.next()
        r.vm.playNext([p])
        r.main.currentPosition = 1
        await r.vm.back()
        #expect(r.vm.currentTrack?.id == 1)
        #expect(nextIDs(r.vm) == [2, 7, 3], "the track left plays first")
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 2)
        // Again, then another album starts: the left track goes with the old context.
        r.main.currentPosition = 1
        await r.vm.back()
        #expect(nextIDs(r.vm).first == 2)
        await r.vm.playTrack(x, queue: [x, y])
        #expect(nextIDs(r.vm) == [7, 9], "Play Next stays, the left track is gone")
    }

    // MARK: S8 — Return after previewing the playing row

    @Test func returnOnThePlayingRowWhilePreviewingItResumesThere() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.vm.preview.toggle(owner: "queue-panel", candidate: .previewable(a))
        await waitUntil { r.vm.preview.isActive && !r.vm.preview.isLoading }
        #expect(r.vm.preview.handOver(a))
        await r.vm.playQueueEntry(r.vm.currentEntryID!)
        #expect(r.main.seeks.last == 30, "from the previewed position (the hot spot)")
        #expect(r.main.state == .playing)
        let seeks = r.main.seeks.count
        // The hand-over is used up: playing the track again starts from the top.
        await r.vm.playTrack(a)
        #expect(r.main.seeks.count == seeks)
    }

    @Test func aHandOverPositionNeverOutlivesNext() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.vm.preview.toggle(owner: "table", candidate: .previewable(b))
        await waitUntil { r.vm.preview.isActive && !r.vm.preview.isLoading }
        #expect(r.vm.preview.handOver(b))
        await r.vm.next()  // not the hand-over's play
        let seeks = r.main.seeks.count
        await r.vm.playTrack(b)
        #expect(r.main.seeks.count == seeks, "no stale preview offset")
    }

    // MARK: Nits

    @Test func anAdvanceKeepsTheEntryIdIntoNowPlayingAndHistory() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        var missing = Track(artist: "Artist", album: "Album", title: "T5", format: "m4a", originalPath: "soundcloud://5")
        missing.id = 5
        await r.vm.playTrack(a, queue: [a, missing, b])
        let passedID = r.vm.queueSnapshot.contextEntries[0].id
        let nextID = r.vm.queueSnapshot.contextEntries[1].id
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 2)
        #expect(r.vm.currentEntryID == nextID)
        #expect(r.vm.historyEntries.map(\.id).suffix(2) == [passedID, nextID], "the passed row keeps its id too")
    }

    @Test func theContextDividerShowsTheListsCurrentName() {
        let origin = PlaybackOrigin(place: .playlist(7), path: [], listKey: "playlist", container: .playlist(id: 7, name: "Warm-up"))
        var renamed = Playlist.createNative(name: "Cool-down")
        renamed.id = 7
        var q = PlaybackQueue()
        q.startContext(track(1), following: [track(2)], cap: 100)
        let content = QueuePanelContent.make(current: nil, currentEntryID: nil, queue: q, history: [], origin: origin,
                                             live: .idle, listNames: .init(playlists: [renamed]))
        #expect(QueuePanelWords.contextHeader(content.contextName) == "From “Cool-down”")
    }

    @Test func wordsAndRoutes() throws {
        #expect(QueuePanelWords.saveTitle == "Save Queue as Playlist")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        // S9: one confirmed route for Play Next; Add to Queue disabled for rows already in Next.
        // W3-SYNC: the failed rows moved from SyncFailedDisclosure into the Last sync section.
        let sync = try source("MLM/Views/Sync/SyncProfileSections.swift")
        #expect(sync.contains("TrackCommandActions.playNext(") && !sync.contains("insertPlayNext"))
        #expect(try source("MLM/App/Commands/TrackCommands.swift").contains("target.addToQueueDisabledReason"))
        #expect(try source("MLM/Views/Queue/QueuePanel.swift").contains("addToQueueDisabledReason: nextIDs.isEmpty ? nil : QueueWords.alreadyQueuedReason"))
        let panel = try source("MLM/Views/Queue/QueuePanel.swift")
        #expect(!panel.contains(".help(\"\")") && !panel.contains("Help : \"\")"), "no empty help text")
        #expect(panel.contains(".onCopyCommand"))
        #expect(panel.contains("secondsSinceTypeSelect: typeSelect.last"))
        // B1: opening the library doesn't wait for the restore.
        let container = try source("MLM/App/DependencyContainer.swift")
        #expect(container.contains("Task { await PlaybackQueuePersister.startLive("))
    }

    // MARK: S10 — the delete cascade

    @Test func deletingTracksRemovesTheirSavedQueueEntries() async throws {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        var t = Track(artist: "A", album: "B", title: "C", format: "m4a", originalPath: "/x.m4a")
        t = try await tracks.insert(t)
        let id = try #require(t.id)
        try await PlaybackQueueRepository(database: db).save(SavedPlaybackQueue(context: [.init(id: UUID(), trackID: id)]))
        try await tracks.delete(ids: [id])
        let left = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playback_queue_entries") }
        #expect(left == 0)

        // A database from before v43 (no table): the delete still works.
        var config = Configuration()
        config.foreignKeysEnabled = false
        let old = try DatabaseQueue(configuration: config)
        try DatabaseManager.buildMigrator().migrate(old, upTo: "v53_tag_write_originals")
        let oldTracks = TrackRepository(database: old)
        let oldTrack = try await oldTracks.insert(Track(artist: "A", album: "B", title: "C", format: "m4a", originalPath: "/y.m4a"))
        try await oldTracks.delete(ids: [try #require(oldTrack.id)])
        #expect(try await old.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") } == 0)
    }
}
