import Foundation

/// LRU cache for playlist detail tables.
///
/// Holds fully-resolved playlist entries (playlist, source, tracks, availability)
/// so navigating back into a previously-viewed playlist renders instantly from
/// memory instead of re-querying SQLite.
///
/// Cap is persisted via UserDefaults (`table_cache_playlist_cap`, default 5).
/// Setting a lower cap evicts the least-recently-used entries immediately.
/// A cap of 0 disables caching (store is a no-op, entry(for:) always returns nil).
@MainActor
@Observable
final class PlaylistTableCache {

    // MARK: - Entry

    struct Entry {
        let playlistId: Int64
        let playlistName: String
        let playlist: Playlist
        let source: Source?
        let tracks: [Track]
        let availabilityByTrackID: [Int64: TrackAvailability]
        let fetchedAt: Date
    }

    /// Lightweight summary exposed to the Settings → Maintenance UI.
    struct Summary: Identifiable {
        let playlistId: Int64
        let name: String
        let trackCount: Int
        let estimatedBytes: Int

        var id: Int64 { playlistId }
    }

    // MARK: - Constants

    static let estimatedBytesPerTrack = 2048
    static let defaultCap = 5
    static let validCapRange = 0...20
    static let userDefaultsKey = "table_cache_playlist_cap"

    // MARK: - State

    private var entries: [Int64: Entry] = [:]
    /// LRU order: most-recently-used at the end.
    private var lruOrder: [Int64] = []

    // MARK: - Cap

    var cap: Int {
        didSet {
            let clamped = Self.validCapRange.clamp(cap)
            if clamped != cap {
                cap = clamped
                return // didSet fires again with the clamped value
            }
            UserDefaults.standard.set(cap, forKey: Self.userDefaultsKey)
            evictIfNeeded()
        }
    }

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.userDefaultsKey)
        let resolved: Int
        if UserDefaults.standard.object(forKey: Self.userDefaultsKey) == nil {
            resolved = Self.defaultCap
        } else {
            resolved = Self.validCapRange.clamp(stored)
        }
        self.cap = resolved
    }

    // MARK: - API

    /// Look up a cached entry and mark it as most-recently-used.
    func entry(for playlistId: Int64) -> Entry? {
        guard cap > 0, let entry = entries[playlistId] else { return nil }
        touch(playlistId)
        return entry
    }

    /// Insert or update an entry. Evicts LRU entries beyond the cap.
    func store(_ entry: Entry) {
        guard cap > 0 else { return }
        let id = entry.playlistId
        if entries[id] != nil {
            // Update in place and refresh recency.
            entries[id] = entry
            touch(id)
        } else {
            entries[id] = entry
            lruOrder.append(id)
        }
        evictIfNeeded()
    }

    /// Remove a single playlist's entry. Used when a real mutation
    /// invalidates the cached rows for that playlist.
    func invalidate(playlistId: Int64) {
        entries.removeValue(forKey: playlistId)
        lruOrder.removeAll { $0 == playlistId }
    }

    /// Remove all cached entries.
    func evictAll() {
        entries.removeAll()
        lruOrder.removeAll()
    }

    /// Alias for evictAll() — invalidates every cached entry.
    func invalidateAll() {
        evictAll()
    }

    /// Summaries in LRU order (least-recently-used first) for the Settings UI.
    var summaries: [Summary] {
        lruOrder.compactMap { id in
            guard let entry = entries[id] else { return nil }
            return Summary(
                playlistId: id,
                name: entry.playlistName,
                trackCount: entry.tracks.count,
                estimatedBytes: entry.tracks.count * Self.estimatedBytesPerTrack
            )
        }
    }

    // MARK: - Internals

    private func touch(_ id: Int64) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    private func evictIfNeeded() {
        if cap == 0 {
            entries.removeAll()
            lruOrder.removeAll()
            return
        }
        while lruOrder.count > cap, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

// MARK: - ClosedRange clamp helper

private extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound {
        min(max(value, lowerBound), upperBound)
    }
}
