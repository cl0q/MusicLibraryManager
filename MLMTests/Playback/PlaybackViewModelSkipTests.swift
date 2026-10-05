import Foundation
import GRDB
import Testing
@testable import MLM

// MARK: - Fakes shared by the W2-C view-model tests

/// An audio player that plays nothing (no sound reaches the output device).
@MainActor
final class SilentAudioPlayer: AudioPlayerControlling {
    var state: AudioPlayer.PlaybackState = .stopped
    var duration: TimeInterval = 200
    var currentPosition: TimeInterval = 0
    private(set) var loaded: [URL] = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var volumes: [Float] = []
    var failLoad = false

    func loadFile(at url: URL) throws {
        state = .stopped
        currentPosition = 0
        if failLoad { throw NSError(domain: "Silent", code: -1) }
        loaded.append(url)
    }
    func play() throws { state = .playing }
    func pause() { if state == .playing { state = .paused } }
    func togglePlayPause() throws { if state == .playing { pause() } else { try play() } }
    func stop() { state = .stopped; currentPosition = 0 }
    func seek(to position: TimeInterval) throws { seeks.append(position); currentPosition = position }
    func setVolume(_ volume: Float) { volumes.append(volume) }
    func applyLUFSCompensation(lufsI: Double?) {}
}

/// A temporary folder with real (tiny) files: playback checks a file exists right before it
/// plays it.
final class PlaybackFixtureFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mlm-w2c-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String) -> String {
        let path = url.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        return path
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class PlaybackTestEnvironment {
    var libraryRoot: String?
    var offlineVolumePath: String?
    var volumeName: String? = "Lexxar"
    var recordedMissing: [Int64] = []
    var fresh: [Int64: Track] = [:]
    var drops: [Int64: Double] = [:]
    let defaults: UserDefaults
    private let suite: String

    init(libraryRoot: String? = nil) {
        self.libraryRoot = libraryRoot
        suite = "mlm.tests.playback.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    var environment: PlaybackEnvironment {
        PlaybackEnvironment(
            libraryRoot: { [unowned self] in self.libraryRoot },
            offlineVolumePath: { [unowned self] in self.offlineVolumePath },
            volumeName: { [unowned self] in self.volumeName },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            recordMissing: { [unowned self] id in self.recordedMissing.append(id) },
            freshTracks: { [unowned self] ids in self.fresh.filter { ids.contains($0.key) } },
            dropOffset: { [unowned self] id in self.drops[id] },
            defaults: defaults
        )
    }
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    // Condition-based (not a fixed sleep): generous ceiling, returns as soon as it holds.
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Tests

/// W2-C: the queue never stalls (PP-MAIN-01), failures are words (PP-MAIN-15), the absolute
/// organized-path join is fixed, Previous follows UC-TB-09, Repeat, volume persistence.
@Suite("PlaybackViewModelSkipTests")
@MainActor
struct PlaybackViewModelSkipTests {

    struct Rig {
        let vm: PlaybackViewModel
        let main: SilentAudioPlayer
        let preview: SilentAudioPlayer
        let env: PlaybackTestEnvironment
        let folder: PlaybackFixtureFolder
        /// Debounces waiting to fire (the test fires them).
        let timers: TimerBox
    }

    @MainActor
    final class TimerBox {
        var pending: [@MainActor () -> Void] = []
        @MainActor func fire() { let all = pending; pending = []; all.forEach { $0() } }
    }

    private func rig(root: Bool = false) -> Rig {
        let folder = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment(libraryRoot: root ? folder.url.path : nil)
        let main = SilentAudioPlayer()
        let preview = SilentAudioPlayer()
        let timers = TimerBox()
        let vm = PlaybackViewModel(audioPlayer: main, environment: env.environment, previewPlayer: { preview },
                                   previewSchedule: { _, work in timers.pending.append(work) })
        return Rig(vm: vm, main: main, preview: preview, env: env, folder: folder, timers: timers)
    }

    /// A Local track whose organized path is an existing absolute file (or a missing one).
    private func local(_ id: Int64, _ rig: Rig, exists: Bool = true) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = exists ? rig.folder.file("\(id).m4a") : rig.folder.url.appendingPathComponent("gone-\(id).m4a").path
        t.duration = 200
        return t
    }

    private func notDownloaded(_ id: Int64) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        return t
    }

    // MARK: Skipping

    @Test func nextSkipsTracksThatArentDownloadedAndSaysSoOnce() async {
        let r = rig()
        let a = local(1, r), b = notDownloaded(2), c = notDownloaded(3), d = local(4, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 4)
        #expect(r.vm.notice?.text == "Skipped 2 tracks that aren’t downloaded")
        #expect(r.vm.notice?.action == .download([b, c]))
        #expect(r.vm.history.map(\.id) == [1, 4], "skipped tracks never enter history")
        #expect(r.main.loaded.count == 2, "nothing is opened for tracks that can't play")
    }

    @Test func nothingPlayableLeftStopsWithTheReasonInThePlayer() async {
        let r = rig()
        let a = local(1, r), b = notDownloaded(2), c = notDownloaded(3)
        await r.vm.playTrack(a, queue: [a, b, c])
        r.main.state = .stopped  // a played to its end
        r.vm.trackDidEnd()
        await waitUntil { r.vm.cantPlay != nil }
        #expect(r.vm.currentTrack == nil)
        #expect(r.vm.cantPlay == CantPlayState(track: b, reason: .notDownloaded))
        #expect(PlayerDisplay.make(current: nil, preview: nil, cantPlay: r.vm.cantPlay).secondLine == "Can’t play — not downloaded")
        #expect(r.vm.upcoming.isEmpty)
        #expect(r.vm.notice?.text == "Skipped 2 tracks that aren’t downloaded")
        // Next again does nothing more — no retry loop.
        let loads = r.main.loaded.count
        await r.vm.next()
        #expect(r.main.loaded.count == loads)
    }

    @Test func aFileFoundMissingAtOpenIsRecordedAndSkipped() async {
        let r = rig()
        let a = local(1, r), gone = local(2, r, exists: false), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, gone, c])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 3)
        #expect(r.env.recordedMissing == [2], "recordMissingAtUse (the monitor checks the folder is reachable)")
        #expect(r.vm.notice?.text == "Skipped “T2” — file missing")
        #expect(r.vm.notice?.action == .locate(gone))
    }

    @Test func anUnpluggedDriveIsNeverAFileProblem() async {
        let r = rig(root: true)
        // Relative paths on the library disk, which is away.
        var a = notDownloaded(1); a.organizedPath = "A/1.m4a"
        var b = notDownloaded(2); b.organizedPath = "A/2.m4a"
        r.folder.file("seed")  // folder exists, the files don't matter: the drive says no first
        r.env.offlineVolumePath = "/Volumes/Lexxar"
        // Persisted verdicts look at where the file lives: relative = the library disk.
        let current = local(9, r)
        await r.vm.playTrack(current, queue: [current, a, b])
        await r.vm.next()
        #expect(r.vm.currentTrack == nil)
        #expect(r.vm.cantPlay?.reason == .driveNotConnected(volumeName: "Lexxar"))
        #expect(r.vm.notice?.text == "Skipped 2 tracks — “Lexxar” is not connected")
        #expect(r.env.recordedMissing.isEmpty, "never flagged missing because of the drive (DEC-014)")
    }

    @Test func freshPersistedStateWinsOverTheQueuedCopy() async {
        let r = rig()
        let a = local(1, r), b = notDownloaded(2)
        await r.vm.playTrack(a, queue: [a, b])
        // b finished downloading after it was queued.
        var downloaded = b
        downloaded.organizedPath = r.folder.file("2.m4a")
        r.env.fresh[2] = downloaded
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 2)
        #expect(r.vm.currentTrack?.organizedPath == downloaded.organizedPath)
    }

    // MARK: The absolute organized-path join (PlaybackViewModel ~165 at v0.9)

    @Test func anAbsoluteOrganizedPathIsUsedAsItIs() async {
        let r = rig(root: true)
        r.env.libraryRoot = "/nonexistent/library"
        let a = local(1, r)
        await r.vm.playTrack(a)
        #expect(r.main.loaded.map(\.path) == [a.organizedPath])
        #expect(PlaybackFileResolver.candidatePaths(a, libraryRoot: "/x").first == a.organizedPath)
        var relative = a
        relative.organizedPath = "Artist/1.m4a"
        #expect(PlaybackFileResolver.candidatePaths(relative, libraryRoot: "/x").first == "/x/Artist/1.m4a")
    }

    @Test func lookupTellsMissingFromDiskAway() {
        var t = notDownloaded(1)
        t.organizedPath = "/Volumes/Gone/a.m4a"
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: nil, fileExists: { _ in false }) == .driveNotConnected(volumePath: "/Volumes/Gone"))
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: nil, fileExists: { $0 == "/Volumes/Gone" }) == .missing)
        t.organizedPath = "A/a.m4a"
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: "/Volumes/Lexxar/Music", fileExists: { _ in false })
                == .driveNotConnected(volumePath: "/Volumes/Lexxar"))
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: "/Volumes/Lexxar/Music", fileExists: { $0.hasSuffix("Music") || $0 == "/Volumes/Lexxar" })
                == .missing)
        t.organizedPath = nil
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: "/x", fileExists: { _ in false }) == .noFile)
    }

    // MARK: Explicit play of something that can't play

    @Test func playingAMissingTrackWhileAnotherPlaysKeepsItPlaying() async {
        let r = rig()
        let a = local(1, r), gone = local(2, r, exists: false)
        await r.vm.playTrack(a)
        await r.vm.playTrack(gone)
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.isMainPlaying)
        #expect(r.vm.cantPlay == nil, "the player keeps naming the playing track")
        #expect(r.vm.notice?.text == "Couldn’t play “T2” — its file is missing")
        #expect(r.vm.notice?.action == .locate(gone))
    }

    @Test func playingAMissingTrackWithNothingLoadedNamesItInThePlayer() async {
        let r = rig()
        let gone = local(2, r, exists: false)
        await r.vm.playTrack(gone)
        #expect(r.vm.cantPlay == CantPlayState(track: gone, reason: .fileMissing))
        let display = PlayerDisplay.make(current: nil, preview: nil, cantPlay: r.vm.cantPlay)
        #expect(display.secondLine == "Can’t play — file missing" && display.fixTitle == "Locate…")
        r.vm.fileWasLocated(trackID: 2)
        #expect(r.vm.cantPlay == nil)
    }

    @Test func anUnreadableFileIsWordedNotRaw() async {
        let r = rig()
        r.main.failLoad = true
        let a = local(1, r)
        await r.vm.playTrack(a)
        #expect(r.vm.notice?.text == "Couldn’t play “T1” — the file can’t be read")
        #expect(r.vm.notice?.action == .showInFinder(URL(fileURLWithPath: a.organizedPath ?? "")), "one action that helps")
        #expect(!(r.vm.notice?.text.contains("Error") ?? true))
    }

    @Test func resumingATrackWhoseDiskIsAwayIsRefusedInWords() async {
        let r = rig(root: true)
        var a = notDownloaded(1)
        a.organizedPath = "A/1.m4a"
        try? FileManager.default.createDirectory(at: r.folder.url.appendingPathComponent("A"), withIntermediateDirectories: true)
        r.folder.file("A/1.m4a")
        await r.vm.playTrack(a)
        r.vm.pause()
        r.env.offlineVolumePath = "/Volumes/Lexxar"
        #expect(r.vm.currentTrackCantPlay == .driveNotConnected(volumeName: "Lexxar"))
        r.vm.togglePlayPause()
        #expect(r.main.state == .paused, "no silent resume from a disk that is away")
        #expect(r.vm.notice?.text == "Can’t play — “Lexxar” is not connected.")
        r.env.offlineVolumePath = nil
        r.vm.play()
        #expect(r.main.state == .playing)
    }

    // MARK: Previous (UC-TB-09)

    @Test func previousRestartsAfterThreeSecondsElseGoesBack() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        await r.vm.next()
        r.main.currentPosition = 3.5
        await r.vm.back()
        #expect(r.vm.currentTrack?.id == 2)
        #expect(r.main.seeks.last == 0)
        r.main.currentPosition = 2
        await r.vm.back()
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.upcoming.first?.id == 2, "the track left comes next again")
    }

    // MARK: Repeat

    @Test func repeatOneReplaysAndRepeatAllWraps() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        r.vm.setRepeatMode(.one)
        await r.vm.playTrack(a, queue: [a, b])
        r.main.state = .stopped
        r.vm.trackDidEnd()
        await waitUntil { r.main.loaded.count == 2 }
        #expect(r.vm.currentTrack?.id == 1)

        r.vm.setRepeatMode(.all)
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 2)
        r.main.state = .stopped
        r.vm.trackDidEnd()
        await waitUntil { r.main.loaded.count == 4 }
        #expect(r.vm.currentTrack?.id == 1, "Repeat All starts the context again")
    }

    @Test func repeatModeIsRemembered() {
        let r = rig()
        r.vm.setRepeatMode(.all)
        let again = PlaybackViewModel(audioPlayer: SilentAudioPlayer(), environment: r.env.environment)
        #expect(again.repeatMode == .all)
    }

    // MARK: Volume (UC-TB-06, IMP-016)

    @Test func volumeIsRememberedAndAppliedAtLaunch() {
        let r = rig()
        r.vm.setVolume(0.3)
        #expect(r.env.defaults.double(forKey: PlaybackViewModel.volumeDefaultsKey) == 0.3)
        let player = SilentAudioPlayer()
        let relaunched = PlaybackViewModel(audioPlayer: player, environment: r.env.environment)
        #expect(relaunched.volume == 0.3)
        #expect(player.volumes.last == 0.3)
        // ⌘↑ / ⌘↓ step a tenth on the grid.
        #expect(PlaybackStep.volume(after: 0.3, up: true) == 0.4)
        #expect(PlaybackStep.volume(after: 0.05, up: false) == 0)
        r.vm.setVolume(1.7)
        #expect(r.vm.volume == 1)
    }

    // MARK: Shuffle

    @Test func shuffleStartsWithAPlayableTrack() async {
        let r = rig()
        let tracks = [notDownloaded(1), local(2, r), notDownloaded(3), local(4, r)]
        for _ in 0..<5 {
            await r.vm.playShuffled(tracks)
            #expect([2, 4].contains(r.vm.currentTrack?.id ?? 0))
        }
    }
}
