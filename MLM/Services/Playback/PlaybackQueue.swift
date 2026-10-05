import Foundation

/// One item of the queue — in Next or in History — with its **own identity** (W2-D, P-QUEUE).
///
/// An entry is not a track id: the same track can be queued twice (or sit in Next and in
/// History at once), and every row, selection, drag, removal, undo step and persisted row
/// addresses exactly one entry. An entry keeps its id when it moves from Next to Now playing
/// and on into History (advance, jump).
struct QueueEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var track: Track
    /// Put back at the front of Next by Previous (the track that was left): it plays first, but
    /// belongs to the context — a new context drops it like the rest of the old one (W2-D
    /// review S7). Cleared when the user moves the entry.
    var returnsToContext = false

    init(id: UUID = UUID(), track: Track, returnsToContext: Bool = false) {
        self.id = id
        self.track = track
        self.returnsToContext = returnsToContext
    }
}

/// The two lanes of Next (UC-TRAIL-05): tracks queued by hand (`Play Next`, `Add to Queue`,
/// drops) and the automatic continuation of the list a track was played from.
enum QueueLane: String, Hashable, Sendable, Codable {
    case playNext
    case context
}

/// Pure value type that models an ordered playback queue with priority lanes.
///
/// Two lanes:
/// - `playNext`: user-pinned tracks that ALWAYS play before context items
///   and survive context switches.
/// - `context`: the surrounding list from a double-click (library row,
///   playlist, search results, etc.), hard-capped.
///
/// Every item is a `QueueEntry` with its own identity; the `[Track]` views (`playNext`,
/// `context`, `upcoming`, `cycle`) are what `QueueAdvance` and older callers read.
///
/// Play Next of a track that is already queued (or in the context) adds **another** entry: the
/// same track twice is allowed, and the context keeps its own entry of it.
///
/// Owns no I/O, no player state — just the entries.
/// The PlaybackViewModel owns a `PlaybackQueue` and drives it from
/// user actions and end-of-track callbacks.
struct PlaybackQueue: Equatable {

    // MARK: - Types

    /// Result of a `back()` call — tells the caller what to do.
    enum BackAction: Equatable {
        /// Seek to 0 and keep playing the current track.
        case restartCurrent
        /// Load and play the given track (the previous one in the queue).
        case play(Track)
    }

    // MARK: - State

    /// Entries the user explicitly pinned to play next.
    /// These are NEVER discarded by context switches (except an entry Previous put back,
    /// `QueueEntry.returnsToContext`).
    private(set) var playNextEntries: [QueueEntry] = []

    /// Context entries from a double-click (library/playlist/search).
    /// Hard-capped; they play AFTER all playNext items.
    private(set) var contextEntries: [QueueEntry] = []

    /// One pass of the context as it was started — the started track and the rows after it
    /// (capped) — as entries: the context entries still queued share their ids, so queue edits
    /// keep the pass in step with the context (W2-D review S1). Repeat All
    /// (`PlaybackRepeatMode.all`) plays it again from the top when the queue runs out. Play
    /// Next items are not part of it.
    private(set) var cycleEntries: [QueueEntry] = []

    /// Changes whenever a new context starts (W2-D review S4): an undo step never puts entries
    /// of an older context into a newer one.
    private(set) var contextID = UUID()

    /// Tracks of the playNext lane.
    var playNext: [Track] { playNextEntries.map(\.track) }

    /// Tracks of the context lane.
    var context: [Track] { contextEntries.map(\.track) }

    /// The tracks of the Repeat All cycle.
    var cycle: [Track] { cycleEntries.map(\.track) }

    /// Ordered upcoming tracks: playNext first, then context.
    var upcoming: [Track] { playNext + context }

    /// Ordered upcoming entries: playNext first, then context (the `Next` section).
    var upcomingEntries: [QueueEntry] { playNextEntries + contextEntries }

    /// Nothing is queued in either lane.
    var isEmpty: Bool { playNextEntries.isEmpty && contextEntries.isEmpty }

    // MARK: - Threshold

    /// Previous restarts the current track when more than this many seconds have played,
    /// else it goes to the previous track (UC-TB-09: 3 s, like Music).
    static let backRestartThreshold: TimeInterval = 3

    // MARK: - Init

    init() {}

    /// A queue with these lanes (restore, edits, tests). `cycle`: the Repeat All pass; context
    /// entries with the same id as a cycle entry are that entry.
    init(playNext: [QueueEntry], context: [QueueEntry], cycle: [QueueEntry] = []) {
        playNextEntries = playNext
        contextEntries = context
        cycleEntries = cycle
    }

    /// A queue whose cycle is given as tracks (tests): the cycle's tail takes the context
    /// entries' identities where the tracks match.
    init(playNext: [QueueEntry], context: [QueueEntry], cycle tracks: [Track]) {
        var cycle = tracks.map { QueueEntry(track: $0) }
        if cycle.count >= context.count {
            let offset = cycle.count - context.count
            for (index, entry) in context.enumerated() where cycle[offset + index].track.id == entry.track.id {
                cycle[offset + index] = entry
            }
        }
        self.init(playNext: playNext, context: context, cycle: cycle)
    }

    // MARK: - Mutation

    /// Advance to the next track. Pops from playNext first, then context.
    /// Returns the new current track, or nil when the queue is exhausted.
    @discardableResult
    mutating func advance() -> Track? {
        advanceEntry()?.track
    }

    /// `advance()` with the entry (its identity and lane).
    @discardableResult
    mutating func advanceEntry() -> QueueEntry? {
        if !playNextEntries.isEmpty {
            return playNextEntries.removeFirst()
        } else if !contextEntries.isEmpty {
            return contextEntries.removeFirst()
        }
        return nil
    }

    /// Replace the context lane, preserving playNext (but dropping an entry Previous put
    /// back — it belonged to the old context). The context keeps its own entries even of
    /// tracks that are also Play Next items.
    ///
    /// - Parameters:
    ///   - tracks: The new context tracks (typically everything after the
    ///     clicked track in the visible list).
    ///   - cap: Maximum number of context tracks to keep.
    mutating func replaceContext(_ tracks: [Track], cap: Int) {
        playNextEntries.removeAll(where: \.returnsToContext)
        contextEntries = tracks.prefix(cap).map { QueueEntry(track: $0) }
        cycleEntries = []
        contextID = UUID()
    }

    /// Start a context: `started` plays now, `following` (capped) come after it. Keeps
    /// playNext; one pass (`started` + context) becomes the Repeat All cycle.
    mutating func startContext(_ started: Track, following: [Track], cap: Int) {
        replaceContext(following, cap: cap)
        cycleEntries = [QueueEntry(track: started)] + contextEntries
    }

    /// Repeat All: put the whole cycle back as the context (playNext stays first), as new
    /// entries — the pass that played keeps its ids in History. Returns whether there was a
    /// cycle to restart.
    @discardableResult
    mutating func restartCycle() -> Bool {
        guard !cycleEntries.isEmpty else { return false }
        cycleEntries = cycleEntries.map { QueueEntry(track: $0.track) }
        contextEntries = cycleEntries
        return true
    }

    /// Insert tracks into the playNext lane (the pre-W2-D behaviour, kept for older callers;
    /// the queue editing API is `QueueEditing`).
    ///
    /// - Tracks already in context are moved to playNext (removed from context).
    /// - Tracks already in playNext are not duplicated.
    mutating func insertPlayNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let newIDs = Set(tracks.compactMap(\.id))

        // Remove from context any tracks being promoted to playNext
        contextEntries.removeAll { entry in
            guard let id = entry.track.id else { return false }
            return newIDs.contains(id)
        }

        // Dedupe against existing playNext
        let existingIDs = Set(playNextEntries.compactMap(\.track.id))
        let toAdd = tracks.filter { t in
            guard let id = t.id else { return true }
            return !existingIDs.contains(id)
        }
        playNextEntries.append(contentsOf: toAdd.map { QueueEntry(track: $0) })
    }

    /// Play a specific track from the upcoming list (pre-W2-D behaviour, kept for older
    /// callers; the queue panel uses `jump(to:)`).
    ///
    /// Discards everything before the track in upcoming, makes it the
    /// implicit "current" (returned), and keeps everything after as the
    /// new context. Clears playNext items up to and including the track.
    ///
    /// Returns the track if found, nil otherwise.
    @discardableResult
    mutating func playFromUpcoming(_ track: Track) -> Track? {
        guard let trackID = track.id else { return nil }
        let all = upcomingEntries
        guard let idx = all.firstIndex(where: { $0.track.id == trackID }) else { return nil }
        let remaining = Array(all.dropFirst(idx + 1))
        playNextEntries = []
        contextEntries = remaining
        return track
    }

    /// Jump to one entry of Next (UC-PRIM-12): it leaves the queue, the entries before it are
    /// returned as passed (they go to History), every entry after it keeps its lane.
    /// - Returns: the entry and the passed entries in queue order, or nil when it isn't queued.
    mutating func jump(to entryID: UUID) -> (entry: QueueEntry, passed: [QueueEntry])? {
        if let index = playNextEntries.firstIndex(where: { $0.id == entryID }) {
            let passed = Array(playNextEntries[..<index])
            let entry = playNextEntries[index]
            playNextEntries.removeFirst(index + 1)
            return (entry, passed)
        }
        if let index = contextEntries.firstIndex(where: { $0.id == entryID }) {
            let passed = playNextEntries + Array(contextEntries[..<index])
            let entry = contextEntries[index]
            playNextEntries = []
            contextEntries.removeFirst(index + 1)
            return (entry, passed)
        }
        return nil
    }

    /// Put a track back at the front of Next (Previous: the track left comes next again). It
    /// plays first; when Play Next items are queued it goes before them, marked as belonging
    /// to the context (`returnsToContext`), so a new context drops it (W2-D review S7).
    mutating func pushToFront(_ track: Track) {
        if playNextEntries.isEmpty {
            contextEntries.insert(QueueEntry(track: track), at: 0)
        } else {
            playNextEntries.insert(QueueEntry(track: track, returnsToContext: true), at: 0)
        }
    }

    /// Put an entry that was just taken out back at the front of its lane (a queue advance that
    /// has to wait keeps the entry's identity).
    mutating func pushToFront(_ entry: QueueEntry, lane: QueueLane) {
        switch lane {
        case .playNext: playNextEntries.insert(entry, at: 0)
        case .context: contextEntries.insert(entry, at: 0)
        }
    }

    /// Replace both lanes (queue edits, restore). The cycle stays.
    mutating func setLanes(playNext: [QueueEntry], context: [QueueEntry]) {
        playNextEntries = playNext
        contextEntries = context
    }

    /// Replace the Repeat All cycle (Clear, its undo, restore, edits).
    mutating func setCycle(_ entries: [QueueEntry]) {
        cycleEntries = entries
    }

    /// The lane an entry is in, if it is queued.
    func lane(of entryID: UUID) -> QueueLane? {
        if playNextEntries.contains(where: { $0.id == entryID }) { return .playNext }
        if contextEntries.contains(where: { $0.id == entryID }) { return .context }
        return nil
    }

    /// Update the stored copies of tracks (fresh rows after an availability or tag change);
    /// entry identities and order stay. Returns whether anything changed.
    @discardableResult
    mutating func refreshTracks(_ fresh: [Int64: Track]) -> Bool {
        guard !fresh.isEmpty else { return false }
        var changed = false
        func refresh(_ entries: inout [QueueEntry]) {
            for index in entries.indices {
                guard let id = entries[index].track.id, let track = fresh[id], track != entries[index].track else { continue }
                entries[index].track = track
                changed = true
            }
        }
        refresh(&playNextEntries)
        refresh(&contextEntries)
        refresh(&cycleEntries)
        return changed
    }

    /// Take out every entry of these tracks (they were removed from the library). Returns
    /// whether anything changed.
    @discardableResult
    mutating func removeTracks(_ trackIDs: Set<Int64>) -> Bool {
        guard !trackIDs.isEmpty else { return false }
        let before = (playNextEntries.count, contextEntries.count, cycleEntries.count)
        playNextEntries.removeAll { $0.track.id.map(trackIDs.contains) ?? false }
        contextEntries.removeAll { $0.track.id.map(trackIDs.contains) ?? false }
        cycleEntries.removeAll { $0.track.id.map(trackIDs.contains) ?? false }
        return before != (playNextEntries.count, contextEntries.count, cycleEntries.count)
    }

    // MARK: - Advances never overwrite edits

    /// The queue an advance commits, rebased on the queue as it is now (W2-D review): edits made
    /// while the advance waited (a slow file lookup) stay. The advance only takes entries out
    /// (what played or was passed over), may put new entries in (a restarted Repeat All pass,
    /// a waiting track put back as a new entry) and may replace the cycle; everything else of
    /// `current` is kept. With nothing edited meanwhile it is `target` exactly.
    static func rebase(_ current: PlaybackQueue, from start: PlaybackQueue, to target: PlaybackQueue) -> PlaybackQueue {
        if current == start { return target }
        let startIDs = Set(start.upcomingEntries.map(\.id))
        let targetIDs = Set(target.upcomingEntries.map(\.id))
        let taken = startIDs.subtracting(targetIDs)
        func merged(_ now: [QueueEntry], _ wanted: [QueueEntry]) -> [QueueEntry] {
            var lane = now.filter { !taken.contains($0.id) }
            // New entries the advance put in: before the first kept entry of the target lane go
            // to the front, the rest to the end.
            let firstKept = wanted.firstIndex { startIDs.contains($0.id) } ?? wanted.count
            let front = wanted[..<firstKept].filter { !startIDs.contains($0.id) }
            let back = wanted[firstKept...].filter { !startIDs.contains($0.id) }
            lane.insert(contentsOf: front, at: 0)
            lane.append(contentsOf: back)
            return lane
        }
        var result = current
        result.setLanes(playNext: merged(current.playNextEntries, target.playNextEntries),
                        context: merged(current.contextEntries, target.contextEntries))
        if target.cycleEntries.map(\.id) != start.cycleEntries.map(\.id) {
            result.setCycle(target.cycleEntries)
        }
        return result
    }
}
