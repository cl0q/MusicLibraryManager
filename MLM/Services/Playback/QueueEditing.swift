import Foundation

// MARK: - Queue editing (W2-D, P-QUEUE, UC-TRAIL-05, DEC-006, DEC-041, DEC-050)
//
// Pure functions over `PlaybackQueue` and the History entries. `PlaybackViewModel` applies them
// at once (an advance in flight rebases its result on the edited queue, `PlaybackQueue.rebase`)
// and hands the receipt to the window's `UndoCenter` (`QueueEditCommands`).
//
// Lane rules
// - `Play Next` puts new entries at the very top of Next (playNext lane, index 0), in the given
//   order. On rows already in Next it moves those entries there (they become Play Next items).
//   A track that is already queued gets another entry.
// - `Add to Queue` puts new entries at the end of the playNext lane — after the last Play Next
//   item, before the context (`queue.html` addNext(end)).
// - A drop / move lands at a `QueuePosition` (lane + index in that lane). Above the
//   `From “‹context›”` divider is the playNext lane, below it the context: an entry dragged
//   from the context above a Play Next item becomes a Play Next item and vice versa
//   (`queue.html` P-QUEUE.N07). A drop of Next rows together with other rows moves the Next
//   rows and adds the others right after them — one step.
// - `Move to End of Queue` moves entries to the very end of Next: the end of the context while
//   the context has entries, else the end of the playNext lane. Entries already at the end, in
//   order, make no step.
// - The Repeat All pass follows the context: entries removed from the context leave it,
//   entries moved within it move in it, entries moved or added into the context join it.
// - `Clear` empties Next: both lanes and the Repeat All cycle — the playing track continues and
//   playback stops after it (`queue.html` P-QUEUE.N03). History stays.
// - `Clear History` empties History except the entry of the playing track.
//
// Undo after the queue moved on
// Every receipt holds the order of Next before and after the edit as identities, and the
// entries it touched. Undo / redo transform the queue *as it is now* from one order to the
// other, touching only those entries:
// - entries the edit added are taken out again (if still queued);
// - entries the edit removed come back — after their nearest earlier neighbour (in the old
//   order) that is still queued, else at the front of their lane;
// - entries the edit moved go back the same way, but only while they are still queued (an
//   entry that played since never comes back);
// - never: an entry that is now playing or in History, a track removed from the library, or a
//   context entry once another context has started (Play Next items still come back).
// With nothing played in between this restores the exact earlier queue, identities included.

/// Where an insertion or a move lands in Next: a lane and an index in that lane.
struct QueuePosition: Equatable, Hashable, Sendable {
    var lane: QueueLane
    var index: Int

    /// The very top of Next (Play Next).
    static let top = QueuePosition(lane: .playNext, index: 0)

    /// A drop at `offset` among the Next rows as the panel lists them: the playNext entries,
    /// then (when the context has entries) the `From “‹context›”` divider row, then the
    /// context entries. Offsets at or above the divider land in the playNext lane.
    static func forDisplayOffset(_ offset: Int, playNextCount: Int, hasDivider: Bool) -> QueuePosition {
        if offset <= playNextCount {
            return QueuePosition(lane: .playNext, index: max(0, offset))
        }
        return QueuePosition(lane: .context, index: max(0, offset - playNextCount - (hasDivider ? 1 : 0)))
    }
}

/// Where a drop lands, named by what the insertion line sits next to, so it is resolved against
/// the queue at the moment the drop is applied (the list may have changed since it was drawn).
enum QueueDropTarget: Equatable, Hashable, Sendable {
    /// A lane and index as they are now.
    case position(QueuePosition)
    /// Just above this entry, in its lane; `fallback` when it left the queue meanwhile.
    case before(UUID, fallback: QueuePosition)
    /// After the last Play Next item (the line sits on the `From “‹context›”` divider).
    case endOfPlayNext
    /// The end of Next.
    case end

    func resolve(in queue: PlaybackQueue) -> QueuePosition {
        switch self {
        case .position(let position):
            return position
        case .before(let id, let fallback):
            if let index = queue.playNextEntries.firstIndex(where: { $0.id == id }) {
                return QueuePosition(lane: .playNext, index: index)
            }
            if let index = queue.contextEntries.firstIndex(where: { $0.id == id }) {
                return QueuePosition(lane: .context, index: index)
            }
            return fallback
        case .endOfPlayNext:
            return QueuePosition(lane: .playNext, index: queue.playNextEntries.count)
        case .end:
            return queue.contextEntries.isEmpty
                ? QueuePosition(lane: .playNext, index: queue.playNextEntries.count)
                : QueuePosition(lane: .context, index: queue.contextEntries.count)
        }
    }
}

/// The order of Next as identities (and lanes) — what an undo step needs, without copies of
/// every queued track.
struct QueueLayout: Equatable, Sendable {
    struct Slot: Equatable, Hashable, Sendable {
        let id: UUID
        let lane: QueueLane
    }

    let slots: [Slot]

    init(_ queue: PlaybackQueue) {
        slots = queue.playNextEntries.map { Slot(id: $0.id, lane: .playNext) }
            + queue.contextEntries.map { Slot(id: $0.id, lane: .context) }
    }

    var ids: [UUID] { slots.map(\.id) }
}

/// What one queue edit did — the value an undo step keeps (`UndoCenter.record`).
struct QueueEditReceipt: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Play Next of tracks (new entries at the top).
        case playNext
        /// Play Next on rows already in Next (moved to the top).
        case moveToTop
        /// Add to Queue (new entries at the end of the playNext lane).
        case addToQueue
        /// A drop of tracks (and possibly Next rows) at a position.
        case insert
        /// Reorder by drag.
        case move
        case moveToEnd
        case remove
        case clearNext
        case clearHistory
    }

    let kind: Kind
    let before: QueueLayout
    let after: QueueLayout
    /// The entries the edit added, removed or moved.
    let touched: Set<UUID>
    /// Copies of the touched entries (to put removed ones back).
    let entries: [UUID: QueueEntry]
    /// The context the edit was made in (`PlaybackQueue.contextID`).
    let contextID: UUID
    /// Clear: the Repeat All cycle it emptied.
    let cycleBefore: [QueueEntry]?
    /// Clear History: the entries it removed, oldest first.
    let historyRemoved: [QueueEntry]
    /// How many tracks the edit concerned (for its sentence).
    let count: Int
    /// The title when it concerned one track.
    let singleTitle: String?
}

/// A queue edit's outcome: the new queue and History, and the receipt.
struct QueueEditResult: Sendable {
    var queue: PlaybackQueue
    var history: [QueueEntry]
    var receipt: QueueEditReceipt
}

/// What an undo / redo must never bring back (W2-D review S2, S3).
struct QueueRestoreLimits: Sendable {
    /// Tracks removed from the library this session.
    var deletedTrackIDs: Set<Int64> = []
    /// Ids that are playing or in History now.
    var elsewhere: Set<UUID> = []

    static let none = QueueRestoreLimits()

    func allows(_ entry: QueueEntry) -> Bool {
        !elsewhere.contains(entry.id) && !(entry.track.id.map(deletedTrackIDs.contains) ?? false)
    }
}

enum QueueEditing {
    // MARK: Adding

    /// Play Next: new entries for `tracks` at the very top of Next, in the given order.
    static func playNext(_ tracks: [Track], queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        insertNew(tracks, at: .top, kind: .playNext, queue: queue, history: history)
    }

    /// Add to Queue: new entries at the end of the playNext lane (before the context).
    static func addToQueue(_ tracks: [Track], queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        insertNew(tracks, at: QueuePosition(lane: .playNext, index: queue.playNextEntries.count),
                  kind: .addToQueue, queue: queue, history: history)
    }

    /// A drop of tracks at `position` (`.top` = Play Next, anywhere else = Add to Queue there).
    static func insert(_ tracks: [Track], at position: QueuePosition, queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        insertNew(tracks, at: position, kind: position == .top ? .playNext : .insert, queue: queue, history: history)
    }

    private static func insertNew(_ tracks: [Track], at position: QueuePosition, kind: QueueEditReceipt.Kind,
                                  queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        let added = tracks.map { QueueEntry(track: $0) }
        guard !added.isEmpty else { return nil }
        var playNext = queue.playNextEntries
        var context = queue.contextEntries
        switch position.lane {
        case .playNext:
            playNext.insert(contentsOf: added, at: clamp(position.index, playNext.count))
        case .context:
            context.insert(contentsOf: added, at: clamp(position.index, context.count))
        }
        var result = queue
        result.setLanes(playNext: playNext, context: context)
        syncCycle(&result, before: queue, touched: Set(added.map(\.id)))
        return QueueEditResult(queue: result, history: history,
                               receipt: receipt(kind, before: queue, after: result, touched: added))
    }

    // MARK: Moving

    /// Move entries of Next to `position` (lane + index in that lane, counted before the move).
    /// They keep their relative order and take the lane of where they land. Nil when nothing
    /// is queued or nothing changes.
    static func move(_ ids: [UUID], to position: QueuePosition, queue: PlaybackQueue, history: [QueueEntry],
                     kind: QueueEditReceipt.Kind = .move) -> QueueEditResult? {
        guard let (result, moving) = moved(ids, to: position, in: queue) else { return nil }
        return QueueEditResult(queue: result, history: history,
                               receipt: receipt(kind, before: queue, after: result, touched: moving))
    }

    /// The move itself (also used by drops). Moved entries lose the Previous marker: the user
    /// placed them.
    private static func moved(_ ids: [UUID], to position: QueuePosition, in queue: PlaybackQueue) -> (PlaybackQueue, [QueueEntry])? {
        let wanted = Set(ids)
        let moving = queue.upcomingEntries.filter { wanted.contains($0.id) }.map { entry -> QueueEntry in
            var placed = entry
            placed.returnsToContext = false
            return placed
        }
        guard !moving.isEmpty else { return nil }
        let movingIDs = Set(moving.map(\.id))
        let laneBefore = position.lane == .playNext ? queue.playNextEntries : queue.contextEntries
        let index = clamp(position.index, laneBefore.count)
        let shift = laneBefore[..<index].filter { movingIDs.contains($0.id) }.count
        var playNext = queue.playNextEntries.filter { !movingIDs.contains($0.id) }
        var context = queue.contextEntries.filter { !movingIDs.contains($0.id) }
        switch position.lane {
        case .playNext: playNext.insert(contentsOf: moving, at: clamp(index - shift, playNext.count))
        case .context: context.insert(contentsOf: moving, at: clamp(index - shift, context.count))
        }
        var result = queue
        result.setLanes(playNext: playNext, context: context)
        guard QueueLayout(result) != QueueLayout(queue) else { return nil }
        syncCycle(&result, before: queue, touched: movingIDs)
        return (result, moving)
    }

    /// Play Next on rows already in Next: they move to the very top (as Play Next items).
    static func moveToTop(_ ids: [UUID], queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        move(ids, to: .top, queue: queue, history: history, kind: .moveToTop)
    }

    /// Move to End of Queue: the very end of Next — the end of the context while it has entries
    /// (context entries stay context entries), else the end of the playNext lane. Nil when the
    /// entries are already the end of Next, in order.
    static func moveToEnd(_ ids: [UUID], queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        let wanted = Set(ids)
        let moving = queue.upcomingEntries.filter { wanted.contains($0.id) }
        guard !moving.isEmpty, queue.upcomingEntries.suffix(moving.count).map(\.id) != moving.map(\.id) else { return nil }
        let position = queue.contextEntries.isEmpty
            ? QueuePosition(lane: .playNext, index: queue.playNextEntries.count)
            : QueuePosition(lane: .context, index: queue.contextEntries.count)
        return move(ids, to: position, queue: queue, history: history, kind: .moveToEnd)
    }

    /// A drop on Next of rows that are queued there (moved) and other tracks (added right after
    /// the moved ones) — one step (W2-D review S6).
    static func drop(moving ids: [UUID], adding tracks: [Track], at position: QueuePosition,
                     queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        let queued = Set(queue.upcomingEntries.map(\.id))
        let movingIDs = ids.filter(queued.contains)
        if movingIDs.isEmpty { return insert(tracks, at: position, queue: queue, history: history) }
        if tracks.isEmpty { return move(movingIDs, to: position, queue: queue, history: history) }
        let (afterMove, moving) = moved(movingIDs, to: position, in: queue)
            ?? (queue, queue.upcomingEntries.filter { Set(movingIDs).contains($0.id) })
        // Right after the last moved entry, in its lane.
        let last = moving.last!.id
        let landing: QueuePosition
        if let index = afterMove.playNextEntries.lastIndex(where: { $0.id == last }) {
            landing = QueuePosition(lane: .playNext, index: index + 1)
        } else {
            landing = QueuePosition(lane: .context, index: (afterMove.contextEntries.lastIndex { $0.id == last } ?? -1) + 1)
        }
        guard let inserted = insertNew(tracks, at: landing, kind: .insert, queue: afterMove, history: history) else { return nil }
        var touched = moving
        touched.append(contentsOf: inserted.queue.upcomingEntries.filter { inserted.receipt.touched.contains($0.id) })
        return QueueEditResult(queue: inserted.queue, history: history,
                               receipt: receipt(.insert, before: queue, after: inserted.queue, touched: touched))
    }

    // MARK: Removing

    /// Remove from Queue (⌫): no question asked (DEC-050).
    static func remove(_ ids: Set<UUID>, queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        let removed = queue.upcomingEntries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return nil }
        var result = queue
        result.setLanes(playNext: queue.playNextEntries.filter { !ids.contains($0.id) },
                        context: queue.contextEntries.filter { !ids.contains($0.id) })
        syncCycle(&result, before: queue, touched: Set(removed.map(\.id)))
        return QueueEditResult(queue: result, history: history,
                               receipt: receipt(.remove, before: queue, after: result, touched: removed))
    }

    /// Clear (Next): both lanes and the Repeat All cycle.
    static func clearNext(queue: PlaybackQueue, history: [QueueEntry]) -> QueueEditResult? {
        let removed = queue.upcomingEntries
        guard !removed.isEmpty || !queue.cycleEntries.isEmpty else { return nil }
        var result = queue
        result.setLanes(playNext: [], context: [])
        result.setCycle([])
        return QueueEditResult(queue: result, history: history,
                               receipt: receipt(.clearNext, before: queue, after: result, touched: removed,
                                                cycleBefore: queue.cycleEntries))
    }

    /// Clear History: every History entry but the playing track's (`keeping`).
    static func clearHistory(queue: PlaybackQueue, history: [QueueEntry], keeping currentEntryID: UUID?) -> QueueEditResult? {
        let removed = history.filter { $0.id != currentEntryID }
        guard !removed.isEmpty else { return nil }
        let layout = QueueLayout(queue)
        let receipt = QueueEditReceipt(kind: .clearHistory, before: layout, after: layout, touched: [], entries: [:],
                                       contextID: queue.contextID, cycleBefore: nil, historyRemoved: removed,
                                       count: removed.count, singleTitle: removed.count == 1 ? removed[0].track.title : nil)
        return QueueEditResult(queue: queue, history: history.filter { $0.id == currentEntryID }, receipt: receipt)
    }

    // MARK: Repeat All follows the context (W2-D review S1)

    /// After a lane edit: the cycle is the part of the pass that already played (cycle entries
    /// that were not queued in the context) followed by the context entries that were part of
    /// the pass or that this edit put into the context. Nothing happens without a cycle.
    static func syncCycle(_ queue: inout PlaybackQueue, before: PlaybackQueue, touched: Set<UUID>) {
        guard !before.cycleEntries.isEmpty else { return }
        let queuedBefore = Set(before.contextEntries.map(\.id))
        let inCycle = Set(before.cycleEntries.map(\.id))
        let played = before.cycleEntries.filter { !queuedBefore.contains($0.id) }
        let pass = queue.contextEntries.filter { inCycle.contains($0.id) || touched.contains($0.id) }
        queue.setCycle(played + pass)
    }

    // MARK: Undo / redo

    /// Undo `receipt` on the queue and History as they are now. `changed` is false when nothing
    /// was left to undo (every touched entry played, went away or isn't allowed back).
    static func revert(_ receipt: QueueEditReceipt, queue: PlaybackQueue, history: [QueueEntry],
                       historyCap: Int, limits: QueueRestoreLimits = .none) -> (queue: PlaybackQueue, history: [QueueEntry], changed: Bool) {
        var result = transform(queue, from: receipt.after, to: receipt.before, receipt: receipt, limits: limits)
        if receipt.kind == .clearNext {
            // The pass comes back with the entries (not on its own: nothing else came back).
            if let cycle = receipt.cycleBefore, !cycle.isEmpty, result.cycleEntries.isEmpty, result.contextID == receipt.contextID,
               result != queue {
                result.setCycle(cycle.filter { $0.track.id.map { !limits.deletedTrackIDs.contains($0) } ?? true })
            }
        } else {
            syncCycle(&result, before: queue, touched: receipt.touched)
        }
        var newHistory = history
        if !receipt.historyRemoved.isEmpty {
            let present = Set(history.map(\.id))
            let back = receipt.historyRemoved.filter { !present.contains($0.id) && limits.allows($0) }
            newHistory = back + history
            if newHistory.count > historyCap { newHistory.removeFirst(newHistory.count - historyCap) }
        }
        return (result, newHistory, result != queue || newHistory != history)
    }

    /// Redo `receipt` on the queue and History as they are now.
    static func reapply(_ receipt: QueueEditReceipt, queue: PlaybackQueue, history: [QueueEntry],
                        limits: QueueRestoreLimits = .none) -> (queue: PlaybackQueue, history: [QueueEntry], changed: Bool) {
        var result = transform(queue, from: receipt.before, to: receipt.after, receipt: receipt, limits: limits)
        if receipt.kind == .clearNext {
            if let cycle = receipt.cycleBefore, !cycle.isEmpty, result.cycleEntries.map(\.id) == cycle.map(\.id) {
                result.setCycle([])
            }
        } else {
            syncCycle(&result, before: queue, touched: receipt.touched)
        }
        var newHistory = history
        if !receipt.historyRemoved.isEmpty {
            let removed = Set(receipt.historyRemoved.map(\.id))
            newHistory.removeAll { removed.contains($0.id) }
        }
        return (result, newHistory, result != queue || newHistory != history)
    }

    /// Change `queue` from order `from` to order `to` for the touched entries only (see the
    /// rules at the top of this file).
    static func transform(_ queue: PlaybackQueue, from: QueueLayout, to: QueueLayout,
                          receipt: QueueEditReceipt, limits: QueueRestoreLimits = .none) -> PlaybackQueue {
        let sameContext = receipt.contextID == queue.contextID
        // Context-lane slots of an older context are left alone (W2-D review S4).
        let touched = receipt.touched.filter { id in
            sameContext || (from.slots.first { $0.id == id }?.lane != .context && to.slots.first { $0.id == id }?.lane != .context)
        }
        guard !touched.isEmpty else { return queue }
        var current: [UUID: QueueEntry] = [:]
        for entry in queue.upcomingEntries where touched.contains(entry.id) { current[entry.id] = entry }
        let inFrom = Set(from.ids)
        var playNext = queue.playNextEntries.filter { !touched.contains($0.id) }
        var context = queue.contextEntries.filter { !touched.contains($0.id) }
        for (index, slot) in to.slots.enumerated() where touched.contains(slot.id) {
            // Still queued (moved back), or added back by this direction (a removal undone).
            // An entry that played since never comes back.
            guard current[slot.id] != nil || !inFrom.contains(slot.id),
                  let entry = current[slot.id] ?? receipt.entries[slot.id],
                  current[slot.id] != nil || limits.allows(entry) else { continue }
            insert(entry, lane: slot.lane, after: to.slots[..<index], playNext: &playNext, context: &context)
        }
        var result = queue
        result.setLanes(playNext: playNext, context: context)
        return result
    }

    /// Insert after the nearest earlier slot that is queued now; without one, at the front of
    /// the entry's lane.
    private static func insert(_ entry: QueueEntry, lane: QueueLane, after earlier: ArraySlice<QueueLayout.Slot>,
                               playNext: inout [QueueEntry], context: inout [QueueEntry]) {
        for neighbour in earlier.reversed() {
            if let index = playNext.firstIndex(where: { $0.id == neighbour.id }) {
                if lane == .playNext {
                    playNext.insert(entry, at: index + 1)
                } else {
                    context.insert(entry, at: 0)
                }
                return
            }
            if let index = context.firstIndex(where: { $0.id == neighbour.id }) {
                if lane == .context {
                    context.insert(entry, at: index + 1)
                } else {
                    playNext.append(entry)
                }
                return
            }
        }
        switch lane {
        case .playNext: playNext.insert(entry, at: 0)
        case .context: context.insert(entry, at: 0)
        }
    }

    // MARK: Helpers

    private static func receipt(_ kind: QueueEditReceipt.Kind, before: PlaybackQueue, after: PlaybackQueue,
                                touched: [QueueEntry], cycleBefore: [QueueEntry]? = nil) -> QueueEditReceipt {
        var entries: [UUID: QueueEntry] = [:]
        for entry in touched { entries[entry.id] = entry }
        return QueueEditReceipt(kind: kind, before: QueueLayout(before), after: QueueLayout(after),
                                touched: Set(entries.keys), entries: entries, contextID: before.contextID,
                                cycleBefore: cycleBefore, historyRemoved: [], count: touched.count,
                                singleTitle: touched.count == 1 ? touched[0].track.title : nil)
    }

    private static func clamp(_ index: Int, _ count: Int) -> Int {
        min(max(index, 0), count)
    }
}

// MARK: - Words (UC-STATUS-05, UC-UNDO-07, `queue.html`)

/// Action names (Edit ▸ Undo ‹name›) and status-bar sentences of queue edits.
enum QueueWords {
    /// Edit ▸ Undo ‹name›.
    static func actionName(_ kind: QueueEditReceipt.Kind) -> String {
        switch kind {
        case .playNext, .moveToTop: "Play Next"
        case .addToQueue, .insert: "Add to Queue"
        case .move: "Reorder Queue"
        case .moveToEnd: "Move to End of Queue"
        case .remove: "Remove from Queue"
        case .clearNext: "Clear Queue"
        case .clearHistory: "Clear History"
        }
    }

    /// The confirmation shown with `Undo` (`queue.html` shapes).
    static func message(_ receipt: QueueEditReceipt) -> String {
        let subject = receipt.singleTitle.map { "“\($0)”" } ?? StatusBarText.tracks(receipt.count)
        switch receipt.kind {
        case .playNext, .moveToTop: return "Playing next: \(subject)"
        case .addToQueue, .insert: return "Added to queue: \(subject)"
        case .move: return "Moved \(subject)"
        case .moveToEnd: return "Moved \(subject) to the end of the queue"
        case .remove: return "Removed \(subject) from the queue"
        case .clearNext: return "Cleared \(StatusBarText.tracks(receipt.count)) from the queue"
        case .clearHistory: return "History cleared"
        }
    }

    /// `… · 1 isn’t downloaded and was left out` (UC-DND-05: skipped items in the same sentence).
    static func leftOutSuffix(_ count: Int) -> String {
        count == 1
            ? " · 1 isn’t downloaded and was left out"
            : " · \(count.formatted(.number)) aren’t downloaded and were left out"
    }

    /// Nothing could be queued: none of the tracks has a file.
    static func nothingToQueue(count: Int) -> String {
        count == 1
            ? "Nothing to queue — the track isn’t downloaded"
            : "Nothing to queue — the \(count.formatted(.number)) tracks aren’t downloaded"
    }

    /// Undo / redo found nothing left to change (the entries played meanwhile, the tracks left
    /// the library or another list started playing).
    static let nothingLeftToUndo = "Nothing to undo — those tracks already left the queue"
    static let nothingLeftToRedo = "Nothing to redo — the queue has moved on"

    /// Track ▸ Add to Queue with rows of Next selected (W2-D review S9).
    static let alreadyQueuedReason = "These tracks are already in the queue."
}
