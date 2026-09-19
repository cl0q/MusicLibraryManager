import Testing
import AppKit
@testable import MLM

@Suite("TrackCoverView (Phase 37)", .serialized)
struct TrackCoverViewTests {

    // MARK: - Stale-image contract (Defect 1 fix)

    /// The `.task(id: trackId)` probe reads from the cache synchronously BEFORE
    /// awaiting `loadImage()`. When the new trackId has no cached image, the
    /// probe returns nil → `image` is cleared → the fallback gradient shows.
    /// This is the observable invariant that prevents a previous track's image
    /// from surviving a trackId change.
    @Test func testCacheProbeReturnsNilForUnknownTrack() {
        let cache = TrackArtworkCache()
        let result = cache.image(forTrackId: 999, size: .small)
        #expect(result == nil, "Synchronous cache probe for unknown track must return nil")
    }

    /// When the new trackId IS already cached, the probe returns the image
    /// immediately (no one-frame placeholder flash).
    @Test func testCacheProbeReturnsImageForKnownTrack() {
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 128, height: 128))
        cache.setImage(image, forTrackId: 42, size: .small)

        let result = cache.image(forTrackId: 42, size: .small)
        #expect(result === image, "Synchronous cache probe for cached track must return the image")
    }

    /// After invalidation (as triggered by `.trackArtworkDidChange`), the probe
    /// returns nil — the view will show the fallback until `loadImage()` resolves.
    @Test func testCacheProbeReturnsNilAfterInvalidation() {
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 128, height: 128))
        cache.setImage(image, forTrackId: 55, size: .small)
        cache.invalidate(forTrackId: 55)

        let result = cache.image(forTrackId: 55, size: .small)
        #expect(result == nil, "After invalidation the probe must return nil")
    }

    // MARK: - Size constants

    @Test func testSizePointsSmall() {
        #expect(ArtworkService.ArtworkSize.small.rawValue == 500)
    }

    @Test func testSizePointsLarge() {
        #expect(ArtworkService.ArtworkSize.large.rawValue == 1200)
    }

    // MARK: - Negative cache prevents redundant DB lookups

    /// When a track is marked as no-artwork, the view's resolveArtwork skips
    /// the DB round-trip. The negative mark survives until explicitly cleared
    /// (by reconcile) or invalidated (by .trackArtworkDidChange).
    @Test func testNegativeCacheSurvivesUntilCleared() {
        let cache = TrackArtworkCache()
        cache.markNoArtwork(trackId: 77)

        #expect(cache.isKnownNoArtwork(trackId: 77) == true)

        cache.clearNegativeEntries()
        #expect(cache.isKnownNoArtwork(trackId: 77) == false)
    }
}
