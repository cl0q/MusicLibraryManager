import Foundation

/// One item of the queue — in Next or in History — with its **own identity** (W2-D, P-QUEUE).
///
/// An entry is not a track id: the same track can be queued twice (or sit in Next and in
/// History at once), and every row, selection, drag, removal, undo step and persisted row
/// addresses exactly one entry.
struct QueueEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var track: Track

    init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
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
/// `context`, `upcoming`) are what `QueueAdvance` and older callers read.
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
    /// These are NEVER discarded by context switches.
    private(set) var playNextEntries: [QueueEntry] = []

    /// Context entries from a double-click (library/playlist/search).
    /// Hard-capped; they play AFTER all playNext items.
    private(set) var contextEntries: [QueueEntry] = []

    /// One pass of the context as it was started — the started track and the rows after it
    /// (capped). Repeat All (`PlaybackRepeatMode.all`) plays it again from the top when the
    /// queue runs out. Play Next items are not part of it.
    private(set) var cycle: [Track] = []

    /// Tracks of the playNext lane.
    var playNext: [Track] { playNextEntries.map(\.track) }

    /// Tracks of the context lane.
    var context: [Track] { contextEntries.map(\.track) }

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

    /// A queue with these lanes (restore, edits, tests).
    init(playNext: [QueueEntry], context: [QueueEntry], cycle: [Track] = []) {
        playNextEntries = playNext
        contextEntries = context
        self.cycle = cycle
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

    /// Replace the context lane, preserving playNext.
    ///
    /// - Parameters:
    ///   - tracks: The new context tracks (typically everything after the
    ///     clicked track in the visible list).
    ///   - cap: Maximum number of context tracks to keep.
    ///
    /// Deduplicates against playNext (by track id) so a track can't be in
    /// both lanes.
    mutating func replaceContext(_ tracks: [Track], cap: Int) {
        let playNextIDs = Set(playNextEntries.compactMap(\.track.id))
        let deduped = tracks.filter { track in
            guard let id = track.id else { return true }
            return !playNextIDs.contains(id)
        }
        contextEntries = deduped.prefix(cap).map { QueueEntry(track: $0) }
        cycle = []
    }

    /// Start a context: `started` plays now, `following` (capped) come after it. Keeps
    /// playNext; one pass (`started` + context) becomes the Repeat All cycle.
    mutating func startContext(_ started: Track, following: [Track], cap: Int) {
        replaceContext(following, cap: cap)
        cycle = [started] + context
    }

    /// Repeat All: put the whole cycle back as the context (playNext stays first). Returns
    /// whether there was a cycle to restart.
    @discardableResult
    mutating func restartCycle() -> Bool {
        guard !cycle.isEmpty else { return false }
        let playNextIDs = Set(playNextEntries.compactMap(\.track.id))
        contextEntries = cycle.filter { track in
            guard let id = track.id else { return true }
            return !playNextIDs.contains(id)
        }.map { QueueEntry(track: $0) }
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

    /// Put a track back at the front of Next as a new entry (Previous: the track left comes
    /// next again). It becomes the first upcoming entry: the front of the playNext lane when
    /// that lane has entries, else the front of the context.
    mutating func pushToFront(_ track: Track) {
        if playNextEntries.isEmpty {
            contextEntries.insert(QueueEntry(track: track), at: 0)
        } else {
            playNextEntries.insert(QueueEntry(track: track), at: 0)
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

    /// Replace the Repeat All cycle (Clear, its undo, restore).
    mutating func setCycle(_ tracks: [Track]) {
        cycle = tracks
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
        for index in cycle.indices {
            guard let id = cycle[index].id, let track = fresh[id], track != cycle[index] else { continue }
            cycle[index] = track
            changed = true
        }
        return changed
    }

    /// Take out every entry of these tracks (they were removed from the library). Returns
    /// whether anything changed.
    @discardableResult
    mutating func removeTracks(_ trackIDs: Set<Int64>) -> Bool {
        guard !trackIDs.isEmpty else { return false }
        let before = (playNextEntries.count, contextEntries.count, cycle.count)
        playNextEntries.removeAll { $0.track.id.map(trackIDs.contains) ?? false }
        contextEntries.removeAll { $0.track.id.map(trackIDs.contains) ?? false }
        cycle.removeAll { $0.id.map(trackIDs.contains) ?? false }
        return before != (playNextEntries.count, contextEntries.count, cycle.count)
    }
}
