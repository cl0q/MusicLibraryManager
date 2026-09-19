import Foundation

/// Pure value type that models an ordered playback queue with priority lanes.
///
/// Two lanes:
/// - `playNext`: user-pinned tracks that ALWAYS play before context items
///   and survive context switches.
/// - `context`: the surrounding list from a double-click (library row,
///   playlist, search results, etc.), hard-capped.
///
/// Owns no I/O, no player state — just the track lists.
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

    /// Tracks the user explicitly pinned to play next.
    /// These are NEVER discarded by context switches.
    private(set) var playNext: [Track] = []

    /// Context tracks from a double-click (library/playlist/search).
    /// Hard-capped; appended AFTER all playNext items.
    private(set) var context: [Track] = []

    /// Ordered upcoming tracks: playNext first, then context.
    var upcoming: [Track] { playNext + context }

    // MARK: - Threshold

    /// Back-button threshold in seconds. When the current position exceeds
    /// this value, pressing back restarts the current track instead of
    /// going to the previous one.
    static let backRestartThreshold: TimeInterval = 7

    // MARK: - Init

    init() {}

    // MARK: - Mutation

    /// Advance to the next track. Pops from playNext first, then context.
    /// Returns the new current track, or nil when the queue is exhausted.
    @discardableResult
    mutating func advance() -> Track? {
        if !playNext.isEmpty {
            return playNext.removeFirst()
        } else if !context.isEmpty {
            return context.removeFirst()
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
        let playNextIDs = Set(playNext.compactMap(\.id))
        let deduped = tracks.filter { track in
            guard let id = track.id else { return true }
            return !playNextIDs.contains(id)
        }
        context = Array(deduped.prefix(cap))
    }

    /// Insert tracks into the playNext lane.
    ///
    /// - Tracks already in context are moved to playNext (removed from context).
    /// - Tracks already in playNext are not duplicated.
    mutating func insertPlayNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let newIDs = Set(tracks.compactMap(\.id))

        // Remove from context any tracks being promoted to playNext
        context.removeAll { t in
            guard let id = t.id else { return false }
            return newIDs.contains(id)
        }

        // Dedupe against existing playNext
        let existingIDs = Set(playNext.compactMap(\.id))
        let toAdd = tracks.filter { t in
            guard let id = t.id else { return true }
            return !existingIDs.contains(id)
        }
        playNext.append(contentsOf: toAdd)
    }

    /// Play a specific track from the upcoming list.
    ///
    /// Discards everything before the track in upcoming, makes it the
    /// implicit "current" (returned), and keeps everything after as the
    /// new context. Clears playNext items up to and including the track.
    ///
    /// Returns the track if found, nil otherwise.
    @discardableResult
    mutating func playFromUpcoming(_ track: Track) -> Track? {
        guard let trackID = track.id else { return nil }
        let all = upcoming
        guard let idx = all.firstIndex(where: { $0.id == trackID }) else { return nil }
        let remaining = Array(all.dropFirst(idx + 1))
        playNext = []
        context = remaining
        return track
    }

    /// Push a track to the front of the context lane (used by back()).
    mutating func pushToFront(_ track: Track) {
        context.insert(track, at: 0)
    }
}
