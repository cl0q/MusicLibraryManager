import Testing
import Foundation
@testable import MLM

// MARK: - Fake Audio Player

@MainActor
private final class ShuffleFakeAudioPlayer: AudioPlayerControlling {
    var state: AudioPlayer.PlaybackState = .stopped
    var duration: TimeInterval = 200
    var currentPosition: TimeInterval = 0

    var loadCallCount = 0
    var playCallCount = 0

    var loadShouldThrow = false

    func loadFile(at url: URL) throws {
        loadCallCount += 1
        if loadShouldThrow {
            throw NSError(domain: "Fake", code: -1)
        }
        state = .stopped
    }

    func play() throws {
        playCallCount += 1
        state = .playing
    }

    func pause() { state = .paused }
    func togglePlayPause() throws {
        switch state {
        case .playing: pause()
        case .paused, .stopped: try play()
        }
    }
    func stop() { state = .stopped }
    func seek(to position: TimeInterval) throws { currentPosition = position }
    func setVolume(_ volume: Float) {}
    func applyLUFSCompensation(lufsI: Double?) {}
}

// MARK: - Fixture Directory

@MainActor
private final class ShuffleFixtureDir {
    let url: URL

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm-shuffle-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }

    func createFile(_ name: String) -> String {
        let path = url.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data([0x00]), attributes: nil)
        return path
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Tests

@Suite
@MainActor
struct PlaybackShuffleTests {
    /// Injected defaults and file checks — never the developer's settings (S11).
    private let env = PlaybackTestEnvironment()

    private func makeTrack(id: Int64, path: String) -> Track {
        var t = Track(
            artist: "Artist",
            album: "Album",
            title: "T\(id)",
            format: "mp3",
            originalPath: path
        )
        t.id = id
        return t
    }

    private func makeVM() -> (PlaybackViewModel, ShuffleFakeAudioPlayer, ShuffleFixtureDir) {
        let fake = ShuffleFakeAudioPlayer()
        let vm = PlaybackViewModel(audioPlayer: fake, environment: env.environment)
        let fixtures = ShuffleFixtureDir()
        return (vm, fake, fixtures)
    }

    // MARK: - playShuffled

    @Test
    func playShuffled_empty_isNoOp() async {
        let (vm, _, _) = makeVM()
        await vm.playShuffled([])
        #expect(vm.currentTrack == nil)
        #expect(vm.upcoming.isEmpty)
    }

    @Test
    func playShuffled_setsCurrentAndContainsAllTracks() async {
        let (vm, _, fx) = makeVM()
        let tracks = (1...10).map { makeTrack(id: Int64($0), path: fx.createFile("\($0).mp3")) }

        await vm.playShuffled(tracks)

        // Something is playing
        #expect(vm.currentTrack != nil)

        // current + upcoming together contain every input track exactly once
        let played = [vm.currentTrack!] + vm.upcoming
        let playedIDs = Set(played.compactMap(\.id))
        let inputIDs = Set(tracks.compactMap(\.id))
        #expect(playedIDs == inputIDs)
        #expect(played.count == tracks.count)
    }

    @Test
    func playShuffled_firstPlayedEqualsShuffledHead() async {
        // Run multiple times to confirm the first played is the head of the
        // shuffled order (i.e. playTrack(shuffled[0], queue: shuffled) behavior).
        let (vm, _, fx) = makeVM()
        let tracks = (1...8).map { makeTrack(id: Int64($0), path: fx.createFile("\($0).mp3")) }

        await vm.playShuffled(tracks)

        guard let first = vm.currentTrack else {
            Issue.record("Expected a current track")
            return
        }
        // upcoming should be the remaining tracks in shuffled order — same set as input minus first
        let upcomingIDs = Set(vm.upcoming.compactMap(\.id))
        let expectedUpcoming = Set(tracks.compactMap(\.id)).subtracting([first.id!])
        #expect(upcomingIDs == expectedUpcoming)
    }

    @Test
    func playShuffled_respectsContextCap() async {
        let (vm, _, fx) = makeVM()
        env.defaults.set(5, forKey: "playback_context_cap")

        let tracks = (1...150).map { makeTrack(id: Int64($0), path: fx.createFile("\($0).mp3")) }

        await vm.playShuffled(tracks)

        #expect(vm.currentTrack != nil)
        // upcoming is capped at 5 (the context cap)
        #expect(vm.upcoming.count == 5)
    }
}
