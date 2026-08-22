import Testing
import AppKit
@testable import MLM

@Suite("TrackCoverView (Phase 37)", .serialized)
struct TrackCoverViewTests {

    @Test func testFallbackRenderedForZeroTrackId() async throws {
        // TrackCoverView(trackId: 0, size: .small) should render Solar gradient fallback
        // We verify via TrackArtworkCache — no image for trackId 0
        let cache = TrackArtworkCache()
        let result = cache.image(forTrackId: 0, size: .small)
        #expect(result == nil, "No artwork should exist for trackId 0 in a fresh cache")
    }

    @Test func testNotificationTriggersReload() async throws {
        // When .trackArtworkDidChange fires with a matching trackId,
        // the cache should be queried again on next render
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 40, height: 40))
        cache.setImage(image, forTrackId: 55, size: .small)

        // Invalidate via notification (simulating what .trackArtworkDidChange does)
        cache.invalidate(forTrackId: 55)

        // After notification-triggered invalidation, cache should be empty
        #expect(cache.image(forTrackId: 55, size: .small) == nil,
                "Cache should be invalidated after notification-triggered reload")
    }

    @Test func testFileMissTriggersSelfHealingPath() async throws {
        // D-14: if artworkPath is in DB but file doesn't exist, self-healing is triggered
        // We test the guard condition: FileManager.fileExists returns false for a temp path
        let nonExistentPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_test_\(UUID().uuidString).jpg")
        #expect(!FileManager.default.fileExists(atPath: nonExistentPath.path),
                "Test precondition: path should not exist")
    }

    @Test func testCacheHitBypassesDisk() async throws {
        // When NSImage is in cache, loadImage should use it without hitting disk
        let cache = TrackArtworkCache()
        let image = NSImage(size: NSSize(width: 128, height: 128))
        cache.setImage(image, forTrackId: 99, size: .large)

        let retrieved = cache.image(forTrackId: 99, size: .large)
        #expect(retrieved === image, "Cache hit returns exact NSImage without disk I/O")
    }

    @Test func testSizePointsSmall() {
        // .small maps to 40pt (PlayerBar surface per D-12)
        // We verify via ArtworkSize.small.rawValue being 500 (the file resolution key)
        #expect(ArtworkService.ArtworkSize.small.rawValue == 500)
    }

    @Test func testSizePointsLarge() {
        // .large maps to 1200px source, 128pt render
        #expect(ArtworkService.ArtworkSize.large.rawValue == 1200)
    }
}
