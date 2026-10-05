import Testing
import Foundation
@testable import MLM

// MARK: - Fake Audio Player

@MainActor
private final class FakeAudioPlayer: AudioPlayerControlling {
    var state: AudioPlayer.PlaybackState = .stopped
    var duration: TimeInterval = 200
    var currentPosition: TimeInterval = 0

    var loadCallCount = 0
    var playCallCount = 0
    var pauseCallCount = 0
    var stopCallCount = 0
    var seekPositions: [TimeInterval] = []
    var volumeValues: [Float] = []
    var lufsValues: [Double?] = []

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

    func pause() {
        pauseCallCount += 1
        state = .paused
    }

    func togglePlayPause() throws {
        switch state {
        case .playing: pause()
        case .paused, .stopped: try play()
        }
    }

    func stop() {
        stopCallCount += 1
        state = .stopped
    }

    func seek(to position: TimeInterval) throws {
        seekPositions.append(position)
        currentPosition = position
    }

    func setVolume(_ volume: Float) {
        volumeValues.append(volume)
    }

    func applyLUFSCompensation(lufsI: Double?) {
        lufsValues.append(lufsI)
    }
}

// MARK: - Fixture Directory

/// Creates real (empty) files on disk so PlaybackViewModel's fileExists
/// checks pass. FakeAudioPlayer never parses them — a few bytes suffice.
@MainActor
private final class FixtureDir {
    let url: URL

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm-fake-\(UUID().uuidString)")
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
struct PlaybackViewModelQueueTests {

    // MARK: - Helpers

    private func makeTrack(id: Int64, path: String, title: String = "T") -> Track {
        var t = Track(
            artist: "Artist",
            album: "Album",
            title: title,
            format: "mp3",
            originalPath: path
        )
        t.id = id
        // A Local track (W2-C: the queue decides from persisted availability — a track without
        // an organized path is Not downloaded and is skipped).
        t.organizedPath = path
        return t
    }

    private func makeVM() -> (PlaybackViewModel, FakeAudioPlayer, FixtureDir) {
        let fake = FakeAudioPlayer()
        let vm = PlaybackViewModel(audioPlayer: fake)
        let fixtures = FixtureDir()
        return (vm, fake, fixtures)
    }

    // MARK: - playTrack(_:queue:)

    @Test
    func playTrackWithQueue_setsCurrentTrackToClickedTrack() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        let c = makeTrack(id: 3, path: fx.createFile("3.mp3"), title: "C")
        await vm.playTrack(b, queue: [a, b, c])
        #expect(vm.currentTrack == b)
    }

    @Test
    func playTrackSingle_setsCurrentTrack() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        await vm.playTrack(a)
        #expect(vm.currentTrack == a)
        #expect(vm.hasTrack)
    }

    // MARK: - trackDidEnd / auto-advance

    @Test
    func trackDidEnd_advancesToNextTrack() async {
        let (vm, fake, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        let c = makeTrack(id: 3, path: fx.createFile("3.mp3"), title: "C")
        await vm.playTrack(b, queue: [a, b, c])
        // Simulate end of track b: fake goes to stopped while VM thinks playing
        fake.state = .stopped
        vm.trackDidEnd()
        // trackDidEnd fires a Task — wait for it (condition-based, not a fixed sleep).
        await waitUntil { vm.currentTrack == c }
        #expect(vm.currentTrack == c)
    }

    @Test
    func trackDidEnd_atEndOfQueue_stops() async {
        let (vm, fake, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        await vm.playTrack(b, queue: [a, b])
        // b is last — simulate end
        fake.state = .stopped
        vm.trackDidEnd()
        await waitUntil { vm.currentTrack == nil }
        #expect(vm.currentTrack == nil)
        #expect(vm.playbackState == .stopped)
    }

    // MARK: - next()

    @Test
    func next_advancesToNextTrack() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        let c = makeTrack(id: 3, path: fx.createFile("3.mp3"), title: "C")
        await vm.playTrack(a, queue: [a, b, c])
        await vm.next()
        #expect(vm.currentTrack == b)
    }

    @Test
    func next_atEnd_stops() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        await vm.playTrack(a, queue: [a])
        await vm.next()
        #expect(vm.currentTrack == nil)
        #expect(vm.playbackState == .stopped)
    }

    // MARK: - back()

    @Test
    func back_below3Seconds_goesToPreviousTrack() async {
        let (vm, fake, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        await vm.playTrack(a, queue: [a, b])
        await vm.playTrack(b, queue: [a, b])
        fake.currentPosition = 3.0
        await vm.back()
        #expect(vm.currentTrack == a)
    }

    @Test
    func back_above3Seconds_restartsCurrentTrack() async {
        let (vm, fake, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        await vm.playTrack(b, queue: [a, b])
        fake.currentPosition = 10.0
        await vm.back()
        #expect(vm.currentTrack == b) // still b
        #expect(fake.seekPositions.contains(0)) // seeked to 0
    }

    @Test
    func back_atFirstTrack_restartsCurrent() async {
        let (vm, fake, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        await vm.playTrack(a)
        fake.currentPosition = 3.0
        await vm.back()
        #expect(vm.currentTrack == a) // still a — no history before
        #expect(fake.seekPositions.contains(0))
    }

    // MARK: - insertPlayNext

    @Test
    func insertPlayNext_addsTracksAfterCurrent() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        let c = makeTrack(id: 3, path: fx.createFile("3.mp3"), title: "C")
        await vm.playTrack(a, queue: [a, b])
        vm.insertPlayNext([c])
        await vm.next() // should go to c (playNext), not b (context)
        #expect(vm.currentTrack == c)
    }

    @Test
    func insertPlayNext_movesAlreadyQueuedTrack() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        let c = makeTrack(id: 3, path: fx.createFile("3.mp3"), title: "C")
        await vm.playTrack(a, queue: [a, b, c])
        vm.insertPlayNext([c]) // move c from context to playNext
        await vm.next() // should go to c (moved to playNext), not b
        #expect(vm.currentTrack == c)
    }

    // MARK: - History

    @Test
    func history_recordsPlayedTracks() async {
        let (vm, _, fx) = makeVM()
        let a = makeTrack(id: 1, path: fx.createFile("1.mp3"), title: "A")
        let b = makeTrack(id: 2, path: fx.createFile("2.mp3"), title: "B")
        await vm.playTrack(a)
        await vm.playTrack(b)
        #expect(vm.history.count == 2)
        #expect(vm.history[0] == a)
        #expect(vm.history[1] == b)
    }

    @Test
    func history_isCapped() async {
        let (vm, _, fx) = makeVM()
        // Set a small cap
        UserDefaults.standard.set(3, forKey: "playback_history_size")
        defer { UserDefaults.standard.removeObject(forKey: "playback_history_size") }

        for i in 1...5 {
            let t = makeTrack(id: Int64(i), path: fx.createFile("\(i).mp3"), title: "T\(i)")
            await vm.playTrack(t)
        }
        #expect(vm.history.count == 3)
        #expect(vm.history.last?.id == 5)
    }

    // MARK: - Play-next survives context switch

    @Test
    func playNextSurvivesContextSwitch() async {
        let (vm, _, fx) = makeVM()
        let pn1 = makeTrack(id: 10, path: fx.createFile("pn1.mp3"), title: "PN1")
        let pn2 = makeTrack(id: 11, path: fx.createFile("pn2.mp3"), title: "PN2")
        let ctx1 = makeTrack(id: 20, path: fx.createFile("ctx1.mp3"), title: "Ctx1")
        let ctx2 = makeTrack(id: 21, path: fx.createFile("ctx2.mp3"), title: "Ctx2")

        // Start with play-next items
        await vm.playTrack(pn1)
        vm.insertPlayNext([pn2])

        // Now double-click a playlist — should NOT lose play-next items
        await vm.playTrack(ctx1, queue: [ctx1, ctx2])

        // Upcoming should be: pn2 (playNext) then ctx2 (context)
        #expect(vm.upcoming.count == 2)
        #expect(vm.upcoming[0] == pn2)
        #expect(vm.upcoming[1] == ctx2)
    }

    // MARK: - Context cap

    @Test
    func contextCap_isApplied() async {
        let (vm, _, fx) = makeVM()
        UserDefaults.standard.set(3, forKey: "playback_context_cap")
        defer { UserDefaults.standard.removeObject(forKey: "playback_context_cap") }

        let tracks = (1...10).map { makeTrack(id: Int64($0), path: fx.createFile("\($0).mp3"), title: "T\($0)") }
        let first = tracks[0]
        await vm.playTrack(first, queue: tracks)
        // Context should be capped at 3 (tracks after first: 9 tracks, capped to 3)
        #expect(vm.upcoming.count == 3)
    }
}
