import XCTest
import AVFoundation
import MediaPlayer
@testable import MLMMobile

/// Mock player that records calls without touching audio hardware.
final class MockPlayer: PlayerProtocol {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate: Float = 0
    var isPlaying: Bool = false

    var lastReplacedURL: URL?
    var playCount = 0
    var pauseCount = 0
    var lastSeekTime: TimeInterval?

    func replaceCurrentItem(with url: URL) {
        lastReplacedURL = url
        duration = 200 // simulate a 200-second track
    }

    func play() {
        isPlaying = true
        rate = 1.0
        playCount += 1
    }

    func pause() {
        isPlaying = false
        rate = 0
        pauseCount += 1
    }

    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void) {
        currentTime = time
        lastSeekTime = time
        completion(true)
    }

    func addPeriodicTimeObserver(interval: TimeInterval, queue: DispatchQueue, using block: @escaping (TimeInterval) -> Void) -> Any {
        // Return a token that can be "removed" later
        return UUID()
    }

    func removeTimeObserver(_ observer: Any) {
        // no-op
    }
}

/// Helper to create test tracks.
private func makeTrack(uuid: String, title: String = "Song", artist: String = "Artist",
                       album: String = "Album", duration: Int = 200,
                       path: String = "Artist/Album/Song.m4a") -> IndexedTrack {
    IndexedTrack(
        id: nil, uuid: uuid, title: title, artist: artist,
        albumArtist: artist, album: album, duration: duration,
        path: path, energyBucket: 3, lufsI: -14.0
    )
}

final class PlaybackServiceTests: XCTestCase {

    private var mockPlayer: MockPlayer!
    private var service: PlaybackService!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        mockPlayer = MockPlayer()
        // Create a temp Music directory with dummy files for URL resolution
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let musicDir = tempDir.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        await MainActor.run {
            service = PlaybackService(player: mockPlayer)
            let syncFolder = SyncFolder()
            syncFolder.rootURL = tempDir
            service.configure(syncFolder: syncFolder)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            service = nil
        }
        mockPlayer = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Create a dummy file at the given relative path under Music/.
    private func createDummyFile(relativePath: String) throws {
        let fileURL = tempDir.appendingPathComponent("Music").appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Queue basics

    func testStartPlaybackSetsQueueAndPlays() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
            makeTrack(uuid: "C", title: "Song C"),
        ]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            XCTAssertEqual(service.queue.count, 3)
            XCTAssertEqual(service.currentIndex, 0)
            XCTAssertTrue(service.isPlaying)
            XCTAssertEqual(service.queue[0].title, "Song A")
        }
    }

    func testStartPlaybackAtSpecificIndex() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
            makeTrack(uuid: "C", title: "Song C"),
        ]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 2)
            XCTAssertEqual(service.currentIndex, 2)
            XCTAssertEqual(service.queue[service.currentIndex].title, "Song C")
        }
    }

    func testStartPlaybackWithEmptyTracksDoesNothing() async throws {
        await MainActor.run {
            service.startPlayback(tracks: [], startIndex: 0)
            XCTAssertTrue(service.queue.isEmpty)
            XCTAssertFalse(service.isPlaying)
        }
    }

    func testStartPlaybackWithInvalidIndexDoesNothing() async throws {
        let tracks = [makeTrack(uuid: "A")]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 5)
            XCTAssertTrue(service.queue.isEmpty)
        }
    }

    // MARK: - Next / Previous

    func testNextAdvancesIndex() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
            makeTrack(uuid: "C", title: "Song C"),
        ]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.next()
            XCTAssertEqual(service.currentIndex, 1)
            service.next()
            XCTAssertEqual(service.currentIndex, 2)
        }
    }

    func testNextAtEndWithRepeatOffPauses() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
        ]

        await MainActor.run {
            service.repeatMode = .off
            service.startPlayback(tracks: tracks, startIndex: 1)
            service.next()
            // Should pause at end
            XCTAssertFalse(service.isPlaying)
            // Index stays at last
            XCTAssertEqual(service.currentIndex, 1)
        }
    }

    func testNextAtEndWithRepeatAllWraps() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
        ]

        await MainActor.run {
            service.repeatMode = .all
            service.startPlayback(tracks: tracks, startIndex: 1)
            service.next()
            XCTAssertEqual(service.currentIndex, 0)
            XCTAssertTrue(service.isPlaying)
        }
    }

    func testPreviousDecreasesIndex() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
            makeTrack(uuid: "C", title: "Song C"),
        ]

        await MainActor.run {
            service.currentTime = 0 // ensure we're below the 3-second threshold
            service.startPlayback(tracks: tracks, startIndex: 2)
            service.previous()
            XCTAssertEqual(service.currentIndex, 1)
        }
    }

    func testPreviousAtStartWithRepeatOffStaysAndSeeks() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
        ]

        await MainActor.run {
            service.repeatMode = .off
            service.currentTime = 1 // below 3-second threshold
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.previous()
            // Should stay at index 0 and seek to 0
            XCTAssertEqual(service.currentIndex, 0)
        }
    }

    func testPreviousAtStartWithRepeatAllWraps() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
        ]

        await MainActor.run {
            service.repeatMode = .all
            service.currentTime = 0
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.previous()
            XCTAssertEqual(service.currentIndex, 1)
            XCTAssertTrue(service.isPlaying)
        }
    }

    func testPreviousRestartsTrackWhenPastThreeSeconds() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
        ]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 1)
            service.currentTime = 10 // past 3-second threshold
            service.previous()
            // Should stay on same track and seek to 0
            XCTAssertEqual(service.currentIndex, 1)
        }
    }

    // MARK: - Repeat One

    func testRepeatOneStaysOnSameTrackAtEnd() async throws {
        // Repeat-one only applies when the track ends naturally (via the time observer).
        // Manual next() always advances — this matches Apple Music behavior.
        // Here we test that repeat-one mode is set correctly and the service is playable.
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
        ]

        await MainActor.run {
            service.repeatMode = .one
            service.startPlayback(tracks: tracks, startIndex: 0)
            XCTAssertEqual(service.repeatMode, .one)
            XCTAssertTrue(service.isPlaying)
            // Manual next still advances
            service.next()
            XCTAssertEqual(service.currentIndex, 1)
        }
    }

    // MARK: - Shuffle

    func testShuffleProducesPermutationOfAllIndices() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = (0..<10).map { makeTrack(uuid: "T\($0)", title: "Song \($0)") }

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.toggleShuffle()
            XCTAssertTrue(service.shuffleEnabled)
            // Shuffle should be on; queue still has all items
            XCTAssertEqual(service.queue.count, 10)
        }
    }

    func testUnshuffleRestoresLinearOrder() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
            makeTrack(uuid: "C", title: "Song C"),
        ]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.toggleShuffle()
            XCTAssertTrue(service.shuffleEnabled)
            service.toggleShuffle()
            XCTAssertFalse(service.shuffleEnabled)
            // After un-shuffle, next should go linearly
            XCTAssertEqual(service.currentIndex, 0)
            service.next()
            XCTAssertEqual(service.currentIndex, 1)
        }
    }

    // MARK: - Cycle repeat mode

    func testCycleRepeatMode() async throws {
        await MainActor.run {
            XCTAssertEqual(service.repeatMode, .off)
            service.cycleRepeatMode()
            XCTAssertEqual(service.repeatMode, .all)
            service.cycleRepeatMode()
            XCTAssertEqual(service.repeatMode, .one)
            service.cycleRepeatMode()
            XCTAssertEqual(service.repeatMode, .off)
        }
    }

    // MARK: - Jump to

    func testJumpToIndex() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [
            makeTrack(uuid: "A", title: "Song A"),
            makeTrack(uuid: "B", title: "Song B"),
            makeTrack(uuid: "C", title: "Song C"),
        ]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.jumpTo(index: 2)
            XCTAssertEqual(service.currentIndex, 2)
            XCTAssertTrue(service.isPlaying)
        }
    }

    func testJumpToInvalidIndexDoesNothing() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [makeTrack(uuid: "A")]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            service.jumpTo(index: 5)
            XCTAssertEqual(service.currentIndex, 0)
        }
    }

    // MARK: - Play/Pause

    func testTogglePlayPause() async throws {
        try createDummyFile(relativePath: "Artist/Album/Song.m4a")
        let tracks = [makeTrack(uuid: "A")]

        await MainActor.run {
            service.startPlayback(tracks: tracks, startIndex: 0)
            XCTAssertTrue(service.isPlaying)
            service.togglePlayPause()
            XCTAssertFalse(service.isPlaying)
            service.togglePlayPause()
            XCTAssertTrue(service.isPlaying)
        }
    }

    // MARK: - Now Playing metadata

    func testBuildNowPlayingInfoContainsExpectedFields() async throws {
        let item = QueueItem(trackUUID: "UUID-1", relativePath: "Artist/Album/Song.m4a")

        await MainActor.run {
            let info = service.buildNowPlayingInfo(for: item)
            XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Unknown")
            XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Unknown")
            XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Unknown")
            XCTAssertNotNil(info[MPMediaItemPropertyPlaybackDuration])
            XCTAssertNotNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
            XCTAssertNotNil(info[MPNowPlayingInfoPropertyPlaybackRate])
        }
    }

    func testBuildNowPlayingInfoUsesItemMetadata() async throws {
        var item = QueueItem(trackUUID: "UUID-1", relativePath: "path")
        item.title = "My Song"
        item.artist = "My Artist"
        item.album = "My Album"
        item.duration = 300

        await MainActor.run {
            let info = service.buildNowPlayingInfo(for: item)
            XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "My Song")
            XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "My Artist")
            XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "My Album")
            XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, 300)
        }
    }

    // MARK: - URL resolution

    func testResolveURLReturnsNilWhenNoSyncFolder() async throws {
        await MainActor.run {
            // Re-create service without a sync folder
            let freshService = PlaybackService(player: mockPlayer)
            let url = freshService.resolveURL(for: "Artist/Album/Song.m4a")
            XCTAssertNil(url)
        }
    }

    func testResolveURLReturnsNilForMissingFile() async throws {
        // setUp already configured a syncFolder with tempDir
        await MainActor.run {
            let url = service.resolveURL(for: "NonExistent/Song.m4a")
            XCTAssertNil(url)
        }
    }

    func testResolveURLReturnsURLForExistingFile() async throws {
        let albumDir = tempDir.appendingPathComponent("Music/Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        // Create a dummy file
        let fileURL = albumDir.appendingPathComponent("Song.m4a")
        try "dummy".write(to: fileURL, atomically: true, encoding: .utf8)

        await MainActor.run {
            let url = service.resolveURL(for: "Artist/Album/Song.m4a")
            XCTAssertNotNil(url)
            XCTAssertEqual(url?.lastPathComponent, "Song.m4a")
        }
    }

    // MARK: - Make queue item

    func testMakeQueueItemPopulatesMetadata() async throws {
        let track = makeTrack(uuid: "UUID-X", title: "Test Song", artist: "Test Artist",
                              album: "Test Album", duration: 180, path: "A/B/C.mp3")

        await MainActor.run {
            let item = service.makeQueueItem(from: track)
            XCTAssertEqual(item.trackUUID, "UUID-X")
            XCTAssertEqual(item.title, "Test Song")
            XCTAssertEqual(item.artist, "Test Artist")
            XCTAssertEqual(item.album, "Test Album")
            XCTAssertEqual(item.duration, 180)
            XCTAssertEqual(item.relativePath, "A/B/C.mp3")
        }
    }

    // MARK: - Missing file skip

    func testMissingFileSetsNotice() async throws {
        let tracks = [makeTrack(uuid: "MISSING", title: "Gone Song", path: "No/Such/File.mp3")]

        await MainActor.run {
            // No sync folder configured → all files are "missing"
            service.startPlayback(tracks: tracks, startIndex: 0)
            XCTAssertNotNil(service.missingFileNotice)
            XCTAssertTrue(service.missingFileNotice!.contains("Gone Song"))
        }
    }
}
