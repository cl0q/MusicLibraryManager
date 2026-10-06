import Foundation

/// ⌥↑ / ⌥↓ in a playlist in Manual order (IMP-117, UC-A11Y-01): the selected rows move one place
/// up or down as a block, as the same undoable reorder a drag makes (`ShellEdits.placeTracks`).
enum PlaylistKeyboardMove {
    /// The reorder plan for moving the selected tracks one place, or nil when it is off
    /// (sorted by a column, filtered) or nothing would move (already first / last).
    ///
    /// - Parameters:
    ///   - selected: the selected tracks (any order).
    ///   - playlistOrder: the playlist's tracks in playlist order.
    ///   - step: `-1` up, `+1` down.
    static func plan(selected: [Int64], playlistOrder: [Int64], step: Int,
                     isPlaylistOrder: Bool, isFiltered: Bool) -> PlaylistDropPlan? {
        guard isPlaylistOrder, !isFiltered, step == -1 || step == 1 else { return nil }
        let chosen = Set(selected)
        let moving = playlistOrder.filter(chosen.contains)
        guard let first = playlistOrder.firstIndex(where: chosen.contains),
              let last = playlistOrder.lastIndex(where: chosen.contains) else { return nil }
        let before: Int64?
        if step < 0 {
            // Before the nearest row above the block that isn't moving.
            guard let above = playlistOrder[..<first].last(where: { !chosen.contains($0) }) else { return nil }
            before = above
        } else {
            // After the nearest row below the block that isn't moving: before the one after it.
            let below = playlistOrder[(last + 1)...].filter { !chosen.contains($0) }
            guard below.count >= 1 else { return nil }
            before = below.count >= 2 ? below[1] : nil
        }
        return PlaylistDropPlan(kind: .reorder, trackIDs: moving, beforeTrackID: before)
    }
}
