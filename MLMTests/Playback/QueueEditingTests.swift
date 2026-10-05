import Foundation
import Testing
@testable import MLM

/// W2-D: the pure queue edits — entry identity, lane rules, undo / redo exact and after the
/// queue moved on.
@Suite("QueueEditingTests")
struct QueueEditingTests {
    private func track(_ id: Int64) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = "A/\(id).m4a"
        return t
    }

    /// Next = playNext `pn`, then context `ctx` (track ids).
    private func queue(pn: [Int64] = [], ctx: [Int64] = [], cycle: [Int64] = []) -> PlaybackQueue {
        PlaybackQueue(playNext: pn.map { QueueEntry(track: track($0)) },
                      context: ctx.map { QueueEntry(track: track($0)) },
                      cycle: cycle.map(track))
    }

    private func ids(_ q: PlaybackQueue) -> (pn: [Int64?], ctx: [Int64?]) {
        (q.playNextEntries.map(\.track.id), q.contextEntries.map(\.track.id))
    }

    // MARK: Adding

    @Test func playNextPutsNewEntriesAtTheTopInOrder() throws {
        let q = queue(pn: [1], ctx: [2, 3])
        let result = try #require(QueueEditing.playNext([track(8), track(9)], queue: q, history: []))
        #expect(ids(result.queue).pn == [8, 9, 1])
        #expect(ids(result.queue).ctx == [2, 3])
        #expect(result.receipt.kind == .playNext)
        #expect(result.receipt.count == 2)
        #expect(QueueWords.message(result.receipt) == "Playing next: 2 tracks")
        #expect(QueueWords.actionName(result.receipt.kind) == "Play Next")
    }

    @Test func theSameTrackCanBeQueuedTwiceAsTwoEntries() throws {
        let q = queue(ctx: [2])
        let once = try #require(QueueEditing.playNext([track(2)], queue: q, history: []))
        let twice = try #require(QueueEditing.addToQueue([track(2)], queue: once.queue, history: []))
        let entries = twice.queue.upcomingEntries
        #expect(entries.map(\.track.id) == [2, 2, 2])
        #expect(Set(entries.map(\.id)).count == 3, "every entry has its own identity")
        // Removing one of them removes exactly that one.
        let removed = try #require(QueueEditing.remove([entries[1].id], queue: twice.queue, history: []))
        #expect(removed.queue.upcomingEntries.map(\.id) == [entries[0].id, entries[2].id])
    }

    @Test func addToQueueGoesAfterTheLastPlayNextItemBeforeTheContext() throws {
        let q = queue(pn: [1, 2], ctx: [3, 4])
        let result = try #require(QueueEditing.addToQueue([track(9)], queue: q, history: []))
        #expect(ids(result.queue).pn == [1, 2, 9])
        #expect(ids(result.queue).ctx == [3, 4])
        #expect(QueueWords.message(result.receipt) == "Added to queue: “T9”")
        #expect(QueueWords.actionName(result.receipt.kind) == "Add to Queue")
    }

    @Test func aDropAtTheTopIsPlayNextAndElsewhereAddsThere() throws {
        let q = queue(pn: [1], ctx: [3, 4])
        let top = try #require(QueueEditing.insert([track(9)], at: .top, queue: q, history: []))
        #expect(top.receipt.kind == .playNext)
        #expect(ids(top.queue).pn == [9, 1])
        let inside = try #require(QueueEditing.insert([track(9)], at: QueuePosition(lane: .context, index: 1), queue: q, history: []))
        #expect(inside.receipt.kind == .insert)
        #expect(ids(inside.queue).ctx == [3, 9, 4])
        // Out-of-range indexes are clamped.
        let end = try #require(QueueEditing.insert([track(9)], at: QueuePosition(lane: .context, index: 99), queue: q, history: []))
        #expect(ids(end.queue).ctx == [3, 4, 9])
        #expect(QueueEditing.insert([], at: .top, queue: q, history: []) == nil)
    }

    @Test func displayOffsetsMapToLanesAroundTheDivider() {
        // Rows: pn0 pn1 | divider | ctx0 ctx1
        #expect(QueuePosition.forDisplayOffset(0, playNextCount: 2, hasDivider: true) == .top)
        #expect(QueuePosition.forDisplayOffset(2, playNextCount: 2, hasDivider: true) == QueuePosition(lane: .playNext, index: 2))
        #expect(QueuePosition.forDisplayOffset(3, playNextCount: 2, hasDivider: true) == QueuePosition(lane: .context, index: 0))
        #expect(QueuePosition.forDisplayOffset(5, playNextCount: 2, hasDivider: true) == QueuePosition(lane: .context, index: 2))
        // No Play Next items: offset 0 is above the divider (Play Next), 1 is the first context slot.
        #expect(QueuePosition.forDisplayOffset(0, playNextCount: 0, hasDivider: true) == .top)
        #expect(QueuePosition.forDisplayOffset(1, playNextCount: 0, hasDivider: true) == QueuePosition(lane: .context, index: 0))
    }

    // MARK: Moving

    @Test func movingWithinALaneKeepsTheOtherEntries() throws {
        let q = queue(ctx: [1, 2, 3, 4])
        let moving = [q.contextEntries[0].id]
        // Drop 1 between 3 and 4 (index 3 counted before the move).
        let result = try #require(QueueEditing.move(moving, to: QueuePosition(lane: .context, index: 3), queue: q, history: []))
        #expect(ids(result.queue).ctx == [2, 3, 1, 4])
        #expect(result.queue.contextEntries[2].id == moving[0], "the entry keeps its identity")
        #expect(QueueWords.message(result.receipt) == "Moved “T1”")
        // Dropping it where it is changes nothing: no step.
        #expect(QueueEditing.move(moving, to: QueuePosition(lane: .context, index: 0), queue: q, history: []) == nil)
        #expect(QueueEditing.move(moving, to: QueuePosition(lane: .context, index: 1), queue: q, history: []) == nil)
    }

    @Test func aContextEntryDraggedAboveTheDividerBecomesAPlayNextItemAndBack() throws {
        let q = queue(pn: [1], ctx: [2, 3])
        let c3 = q.contextEntries[1].id
        let up = try #require(QueueEditing.move([c3], to: QueuePosition(lane: .playNext, index: 0), queue: q, history: []))
        #expect(ids(up.queue).pn == [3, 1])
        #expect(ids(up.queue).ctx == [2])
        let p1 = q.playNextEntries[0].id
        let down = try #require(QueueEditing.move([p1], to: QueuePosition(lane: .context, index: 1), queue: q, history: []))
        #expect(ids(down.queue).pn.isEmpty)
        #expect(ids(down.queue).ctx == [2, 1, 3])
    }

    @Test func severalEntriesMoveTogetherInQueueOrder() throws {
        let q = queue(pn: [1], ctx: [2, 3, 4, 5])
        let picked = [q.contextEntries[2].id, q.playNextEntries[0].id]  // 4 and 1, given out of order
        let result = try #require(QueueEditing.move(picked, to: QueuePosition(lane: .context, index: 4), queue: q, history: []))
        #expect(ids(result.queue).ctx == [2, 3, 5, 1, 4])
        #expect(QueueWords.message(result.receipt) == "Moved 2 tracks")
    }

    @Test func playNextOnQueuedRowsMovesThemToTheTopAndMoveToEndToTheEnd() throws {
        let q = queue(pn: [1], ctx: [2, 3, 4])
        let three = q.contextEntries[1].id
        let top = try #require(QueueEditing.moveToTop([three], queue: q, history: []))
        #expect(ids(top.queue).pn == [3, 1])
        #expect(top.receipt.kind == .moveToTop)
        #expect(QueueWords.message(top.receipt) == "Playing next: “T3”")
        let one = q.playNextEntries[0].id
        let end = try #require(QueueEditing.moveToEnd([one], queue: q, history: []))
        #expect(ids(end.queue).pn.isEmpty)
        #expect(ids(end.queue).ctx == [2, 3, 4, 1])
        #expect(QueueWords.message(end.receipt) == "Moved “T1” to the end of the queue")
        // Only Play Next items: the end of that lane.
        let onlyPlayNext = queue(pn: [1, 2])
        let pnEnd = try #require(QueueEditing.moveToEnd([onlyPlayNext.playNextEntries[0].id], queue: onlyPlayNext, history: []))
        #expect(ids(pnEnd.queue).pn == [2, 1])
    }

    // MARK: Removing and clearing

    @Test func removeTakesOutExactlyTheEntries() throws {
        let q = queue(pn: [1], ctx: [2, 3])
        let result = try #require(QueueEditing.remove([q.contextEntries[0].id, q.playNextEntries[0].id], queue: q, history: []))
        #expect(ids(result.queue).pn.isEmpty)
        #expect(ids(result.queue).ctx == [3])
        #expect(QueueWords.message(result.receipt) == "Removed 2 tracks from the queue")
        #expect(QueueWords.actionName(.remove) == "Remove from Queue")
        #expect(QueueEditing.remove([UUID()], queue: q, history: []) == nil, "nothing queued: no step")
    }

    @Test func clearEmptiesNextAndTheCycleButNotHistory() throws {
        let history = [QueueEntry(track: track(7))]
        let q = queue(pn: [1], ctx: [2, 3], cycle: [5, 2, 3])
        let result = try #require(QueueEditing.clearNext(queue: q, history: history))
        #expect(result.queue.isEmpty)
        #expect(result.queue.cycle.isEmpty, "playback stops after the playing track, also with Repeat All")
        #expect(result.history == history)
        #expect(QueueWords.message(result.receipt) == "Cleared 3 tracks from the queue")
        #expect(QueueWords.actionName(.clearNext) == "Clear Queue")
        #expect(QueueEditing.clearNext(queue: PlaybackQueue(), history: history) == nil)
    }

    @Test func clearHistoryKeepsThePlayingEntry() throws {
        let history = [QueueEntry(track: track(1)), QueueEntry(track: track(2)), QueueEntry(track: track(3))]
        let result = try #require(QueueEditing.clearHistory(queue: PlaybackQueue(), history: history, keeping: history[2].id))
        #expect(result.history == [history[2]])
        #expect(QueueWords.message(result.receipt) == "History cleared")
        let undone = QueueEditing.revert(result.receipt, queue: result.queue, history: result.history, historyCap: 50)
        #expect(undone.history == history)
        #expect(undone.changed)
        let redone = QueueEditing.reapply(result.receipt, queue: undone.queue, history: undone.history)
        #expect(redone.history == [history[2]])
    }

    // MARK: Undo / redo

    @Test func undoRestoresTheExactQueueAndRedoTheEditForEveryKind() throws {
        let q = queue(pn: [1, 2], ctx: [3, 4, 5], cycle: [9, 3, 4, 5])
        let p = q.playNextEntries, c = q.contextEntries
        let edits: [QueueEditResult] = [
            try #require(QueueEditing.playNext([track(8)], queue: q, history: [])),
            try #require(QueueEditing.addToQueue([track(8)], queue: q, history: [])),
            try #require(QueueEditing.insert([track(8)], at: QueuePosition(lane: .context, index: 2), queue: q, history: [])),
            try #require(QueueEditing.move([c[2].id, p[0].id], to: QueuePosition(lane: .context, index: 1), queue: q, history: [])),
            try #require(QueueEditing.moveToTop([c[1].id], queue: q, history: [])),
            try #require(QueueEditing.moveToEnd([p[1].id], queue: q, history: [])),
            try #require(QueueEditing.remove([p[1].id, c[0].id], queue: q, history: [])),
            try #require(QueueEditing.clearNext(queue: q, history: [])),
        ]
        for edit in edits {
            let undone = QueueEditing.revert(edit.receipt, queue: edit.queue, history: [], historyCap: 50)
            #expect(undone.queue == q, "undo of \(edit.receipt.kind) restores identities, lanes, order and the cycle")
            #expect(undone.changed)
            let redone = QueueEditing.reapply(edit.receipt, queue: undone.queue, history: [])
            #expect(redone.queue == edit.queue, "redo of \(edit.receipt.kind)")
        }
    }

    @Test func undoOfARemoveAfterTheQueueAdvancedPutsItBackNextToItsNeighbour() throws {
        // [1, 2, 3, 4]: remove 3; then 1 and 2 play.
        let q = queue(ctx: [1, 2, 3, 4])
        let removed = try #require(QueueEditing.remove([q.contextEntries[2].id], queue: q, history: []))
        var advanced = removed.queue
        advanced.advance()
        advanced.advance()
        #expect(ids(advanced).ctx == [4])
        let undone = QueueEditing.revert(removed.receipt, queue: advanced, history: [], historyCap: 50)
        #expect(ids(undone.queue).ctx == [3, 4], "its earlier neighbours are gone: the front of its lane")
        #expect(undone.queue.contextEntries[0].id == q.contextEntries[2].id)

        // Only 1 played: 3 goes back after 2, its nearest earlier neighbour still queued.
        var once = removed.queue
        once.advance()
        let undoneOnce = QueueEditing.revert(removed.receipt, queue: once, history: [], historyCap: 50)
        #expect(ids(undoneOnce.queue).ctx == [2, 3, 4])
    }

    @Test func undoOfAMoveNeverBringsBackAnEntryThatPlayed() throws {
        let q = queue(ctx: [1, 2, 3])
        let moved = try #require(QueueEditing.moveToTop([q.contextEntries[2].id], queue: q, history: []))
        var played = moved.queue
        #expect(played.advance()?.id == 3)
        let undone = QueueEditing.revert(moved.receipt, queue: played, history: [], historyCap: 50)
        #expect(ids(undone.queue).ctx == [1, 2])
        #expect(!undone.changed, "nothing left to undo")
    }

    @Test func undoOfPlayNextAfterItPlayedChangesNothing() throws {
        let q = queue(ctx: [1, 2])
        let added = try #require(QueueEditing.playNext([track(9)], queue: q, history: []))
        var played = added.queue
        #expect(played.advance()?.id == 9)
        let undone = QueueEditing.revert(added.receipt, queue: played, history: [], historyCap: 50)
        #expect(!undone.changed)
        #expect(ids(undone.queue).ctx == [1, 2])
    }

    @Test func undoOfClearKeepsWhatWasQueuedAfterwards() throws {
        let q = queue(pn: [1], ctx: [2, 3], cycle: [2, 3])
        let cleared = try #require(QueueEditing.clearNext(queue: q, history: []))
        let later = try #require(QueueEditing.playNext([track(9)], queue: cleared.queue, history: []))
        let undone = QueueEditing.revert(cleared.receipt, queue: later.queue, history: [], historyCap: 50)
        #expect(ids(undone.queue).pn == [1, 9])
        #expect(ids(undone.queue).ctx == [2, 3])
        #expect(undone.queue.cycle.map(\.id) == [2, 3])
    }

    @Test func historyUndoRespectsTheCap() throws {
        let history = (1...4).map { QueueEntry(track: track(Int64($0))) }
        let cleared = try #require(QueueEditing.clearHistory(queue: PlaybackQueue(), history: history, keeping: history[3].id))
        // Two new plays happened since; the cap is 4.
        let now = cleared.history + [QueueEntry(track: track(5)), QueueEntry(track: track(6))]
        let undone = QueueEditing.revert(cleared.receipt, queue: PlaybackQueue(), history: now, historyCap: 4)
        #expect(undone.history.map(\.track.id) == [3, 4, 5, 6], "the oldest give way")
    }
}
