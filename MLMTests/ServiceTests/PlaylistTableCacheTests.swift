import Foundation
import Testing
@testable import MLM

@Suite("PlaylistTableCache (LRU)")
@MainActor
struct PlaylistTableCacheTests {

    private let userDefaultsKey = PlaylistTableCache.userDefaultsKey

    private func makeEntry(playlistId: Int64, name: String = "Playlist", trackCount: Int = 10) -> PlaylistTableCache.Entry {
        var p = Playlist(
            id: playlistId,
            name: name,
            description: nil,
            category: "native",
            isLiked: 0,
            isSmart: 0,
            isPinned: 0
        )
        let tracks = (0..<trackCount).map { i in
            Track.makePlaceholder(id: Int64(i + 1))
        }
        return PlaylistTableCache.Entry(
            playlistId: playlistId,
            playlistName: name,
            playlist: p,
            source: nil,
            tracks: tracks,
            availabilityByTrackID: [:],
            fetchedAt: Date()
        )
    }

    private func makeCache() -> PlaylistTableCache {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        return PlaylistTableCache()
    }

    // MARK: - Basic store / retrieve

    @Test func storeAndRetrieve() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        let entry = makeEntry(playlistId: 1, name: "Rock")
        cache.store(entry)

        let retrieved = cache.entry(for: 1)
        #expect(retrieved?.playlistId == 1)
        #expect(retrieved?.playlistName == "Rock")
        #expect(retrieved?.tracks.count == 10)
    }

    @Test func missReturnsNil() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        #expect(cache.entry(for: 999) == nil)
    }

    // MARK: - LRU eviction

    @Test func lruEvictionBeyondCap() {
        let cache = makeCache()
        cache.cap = 3
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, name: "A"))
        cache.store(makeEntry(playlistId: 2, name: "B"))
        cache.store(makeEntry(playlistId: 3, name: "C"))
        // All three should be present
        #expect(cache.entry(for: 1) != nil)
        #expect(cache.entry(for: 2) != nil)
        #expect(cache.entry(for: 3) != nil)

        // Adding a 4th should evict the LRU (1, since 2 and 3 were touched by entry(for:))
        cache.store(makeEntry(playlistId: 4, name: "D"))
        #expect(cache.entry(for: 1) == nil, "playlist 1 should be evicted (LRU)")
        #expect(cache.entry(for: 2) != nil)
        #expect(cache.entry(for: 3) != nil)
        #expect(cache.entry(for: 4) != nil)
    }

    @Test func touchUpdatesRecency() {
        let cache = makeCache()
        cache.cap = 3
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, name: "A"))
        cache.store(makeEntry(playlistId: 2, name: "B"))
        cache.store(makeEntry(playlistId: 3, name: "C"))

        // Touch playlist 1 to make it most-recently-used
        _ = cache.entry(for: 1)

        // Adding a 4th should now evict playlist 2 (the new LRU)
        cache.store(makeEntry(playlistId: 4, name: "D"))
        #expect(cache.entry(for: 1) != nil, "playlist 1 was touched — should survive")
        #expect(cache.entry(for: 2) == nil, "playlist 2 should be evicted (LRU after touch)")
        #expect(cache.entry(for: 3) != nil)
        #expect(cache.entry(for: 4) != nil)
    }

    // MARK: - Cap changes

    @Test func capLoweredEvictsImmediately() {
        let cache = makeCache()
        cache.cap = 5
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        for i in Int64(1)...5 {
            cache.store(makeEntry(playlistId: i, name: "P\(i)"))
        }
        #expect(cache.summaries.count == 5)

        cache.cap = 2
        #expect(cache.summaries.count == 2, "lowering cap should evict to new size")
    }

    @Test func capZeroDisablesCaching() {
        let cache = makeCache()
        cache.cap = 0
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1))
        #expect(cache.entry(for: 1) == nil, "cap 0 should store nothing")
        #expect(cache.summaries.isEmpty)
    }

    // MARK: - Estimated bytes

    @Test func estimatedBytesMath() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, trackCount: 100))
        let summary = cache.summaries.first
        #expect(summary?.estimatedBytes == 100 * PlaylistTableCache.estimatedBytesPerTrack)
    }

    // MARK: - Update in place

    @Test func storeUpdatesExistingEntryInPlace() {
        let cache = makeCache()
        cache.cap = 3
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, name: "Old", trackCount: 5))
        cache.store(makeEntry(playlistId: 2, name: "B"))
        cache.store(makeEntry(playlistId: 3, name: "C"))

        // Update entry 1 with new data
        cache.store(makeEntry(playlistId: 1, name: "New", trackCount: 20))

        let retrieved = cache.entry(for: 1)
        #expect(retrieved?.playlistName == "New")
        #expect(retrieved?.tracks.count == 20)
        // Count should still be 3 (update in place, not a new insertion)
        #expect(cache.summaries.count == 3)
    }

    // MARK: - evictAll

    @Test func evictAllClearsCache() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1))
        cache.store(makeEntry(playlistId: 2))
        #expect(cache.summaries.count == 2)

        cache.evictAll()
        #expect(cache.summaries.isEmpty)
        #expect(cache.entry(for: 1) == nil)
    }

    // MARK: - Invalidation

    @Test func invalidateRemovesOnlyTargetEntry() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, name: "A"))
        cache.store(makeEntry(playlistId: 2, name: "B"))
        cache.store(makeEntry(playlistId: 3, name: "C"))

        cache.invalidate(playlistId: 2)

        #expect(cache.entry(for: 1) != nil, "playlist 1 should survive")
        #expect(cache.entry(for: 2) == nil, "playlist 2 should be invalidated")
        #expect(cache.entry(for: 3) != nil, "playlist 3 should survive")
    }

    @Test func invalidateAllEmptiesCache() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1))
        cache.store(makeEntry(playlistId: 2))
        cache.store(makeEntry(playlistId: 3))

        cache.invalidateAll()

        #expect(cache.summaries.isEmpty)
        #expect(cache.entry(for: 1) == nil)
        #expect(cache.entry(for: 2) == nil)
        #expect(cache.entry(for: 3) == nil)
    }

    @Test func summariesUpdateAfterInvalidation() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, name: "A"))
        cache.store(makeEntry(playlistId: 2, name: "B"))
        #expect(cache.summaries.count == 2)

        cache.invalidate(playlistId: 1)
        #expect(cache.summaries.count == 1)
        #expect(cache.summaries.first?.playlistId == 2)
    }

    @Test func invalidatedIdThenStoreWorks() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1, name: "Old", trackCount: 5))
        cache.invalidate(playlistId: 1)
        #expect(cache.entry(for: 1) == nil)

        cache.store(makeEntry(playlistId: 1, name: "New", trackCount: 20))
        let retrieved = cache.entry(for: 1)
        #expect(retrieved?.playlistName == "New")
        #expect(retrieved?.tracks.count == 20)
    }

    @Test func invalidateNonExistentIdIsNoOp() {
        let cache = makeCache()
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        cache.store(makeEntry(playlistId: 1))
        cache.invalidate(playlistId: 999)
        #expect(cache.entry(for: 1) != nil)
        #expect(cache.summaries.count == 1)
    }

    // MARK: - UserDefaults persistence

    @Test func capPersistedViaUserDefaults() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        let cache1 = PlaylistTableCache()
        cache1.cap = 7
        #expect(UserDefaults.standard.integer(forKey: userDefaultsKey) == 7)

        // New instance should pick up the persisted value
        let cache2 = PlaylistTableCache()
        #expect(cache2.cap == 7)

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    @Test func defaultCapWhenNoUserDefaultsValue() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        let cache = PlaylistTableCache()
        #expect(cache.cap == PlaylistTableCache.defaultCap)
    }
}

// MARK: - Test helper

private extension Track {
    /// Minimal placeholder track for cache tests — only id is meaningful.
    static func makePlaceholder(id: Int64) -> Track {
        Track(
            id: id,
            artist: "Artist",
            albumArtist: "Artist",
            album: "Album",
            title: "Track \(id)",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: nil,
            format: "m4a",
            originalPath: "/tmp/track_\(id).m4a",
            organizedPath: nil,
            isDuplicate: 0,
            dateAdded: "2025-01-01",
            dateAddedLibrary: nil,
            variantOf: nil,
            downloadStatus: nil,
            downloadFailure: nil,
            lufsI: nil,
            lufsRange: nil,
            truePeak: nil,
            energyBucket: nil,
            danceability: nil,
            bpm: nil,
            albumId: nil,
            searchText: nil
        )
    }
}
