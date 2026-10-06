import Foundation

/// The order of the sidebar's Sync section (IMP-106) — pure, so every cell is a unit test.
enum SyncProfileOrder {
    /// `current` with `moving` placed (in their given order) before `before`; `nil` = at the end.
    /// A profile is never placed before itself; unknown ids are ignored.
    static func moved(_ moving: [Int64], before: Int64?, in current: [Int64]) -> [Int64] {
        let known = Set(current)
        var seen = Set<Int64>()
        let moved = moving.filter { known.contains($0) && $0 != before && seen.insert($0).inserted }
        guard !moved.isEmpty else { return current }
        let rest = current.filter { !seen.contains($0) }
        let index = before.flatMap { rest.firstIndex(of: $0) } ?? rest.count
        return Array(rest[..<index]) + moved + Array(rest[index...])
    }
}
