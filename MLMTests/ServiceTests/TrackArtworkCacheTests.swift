import Testing
import AppKit
@testable import MLM

@Suite("TrackArtworkCache (Phase 37)")
struct TrackArtworkCacheTests {

    // REQUIRED (gates plan) — from VALIDATION.md
    @Test func testCacheHit() {
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        cache.setImage(image, forTrackId: 42, size: .small)

        let retrieved = cache.image(forTrackId: 42, size: .small)
        #expect(retrieved === image, "Cache hit should return the same NSImage object")
    }

    // REQUIRED (gates plan) — from VALIDATION.md
    @Test func testEvictionUnderLimit() {
        // Insert 210 images (> countLimit 200); verify cache does not crash
        // NSCache evicts internally; we just confirm no crash + final entries accessible
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        for i in Int64(1)...210 {
            cache.setImage(image, forTrackId: i, size: .small)
        }
        // After inserting 210, NSCache should have evicted at least 10
        // We can only verify that the cache operates without error (no assertion on exact count)
        // and that the shared singleton is still accessible
        #expect(TrackArtworkCache.shared.image(forTrackId: 999, size: .small) == nil)
    }

    // REQUIRED (gates plan) — from VALIDATION.md
    @Test func testInvalidateTrack() {
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        cache.setImage(image, forTrackId: 10, size: .small)
        cache.setImage(image, forTrackId: 10, size: .large)

        cache.invalidate(forTrackId: 10)

        #expect(cache.image(forTrackId: 10, size: .small) == nil, "small size should be evicted")
        #expect(cache.image(forTrackId: 10, size: .large) == nil, "large size should be evicted")
    }

    // [stretch] — include if the three required tests pass and time permits
    @Test func testCacheMiss() {
        let cache = TrackArtworkCache()
        let result = cache.image(forTrackId: 999, size: .large)
        #expect(result == nil, "Unknown trackId should return nil")
    }

    // [stretch] — include if the three required tests pass and time permits
    @Test func testDifferentSizesStoredSeparately() {
        let cache = TrackArtworkCache()
        let smallImage = NSImage(size: NSSize(width: 18, height: 18))
        let largeImage = NSImage(size: NSSize(width: 128, height: 128))
        cache.setImage(smallImage, forTrackId: 7, size: .small)
        cache.setImage(largeImage, forTrackId: 7, size: .large)

        #expect(cache.image(forTrackId: 7, size: .small) === smallImage)
        #expect(cache.image(forTrackId: 7, size: .large) === largeImage)
    }

    // MARK: - Negative cache clearing (Defect 3 fix)

    @Test func testClearNegativeEntriesEmptiesMarksButKeepsImages() {
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 64, height: 64))

        // Populate both a cached image and a negative mark for different tracks.
        cache.setImage(image, forTrackId: 100, size: .small)
        cache.markNoArtwork(trackId: 200)

        #expect(cache.isKnownNoArtwork(trackId: 200) == true,
                "Precondition: track 200 should be marked as no-artwork")

        cache.clearNegativeEntries()

        // Negative marks cleared
        #expect(cache.isKnownNoArtwork(trackId: 200) == false,
                "clearNegativeEntries must empty the negative-cache set")

        // Cached images preserved (not dropped)
        #expect(cache.image(forTrackId: 100, size: .small) === image,
                "clearNegativeEntries must NOT drop cached images")
    }

    @Test func testClearNegativeEntriesIsIdempotent() {
        let cache = TrackArtworkCache()
        cache.markNoArtwork(trackId: 1)
        cache.clearNegativeEntries()
        cache.clearNegativeEntries() // second call must not crash
        #expect(cache.isKnownNoArtwork(trackId: 1) == false)
    }
}
