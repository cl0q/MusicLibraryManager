import Foundation
import GRDB
import Testing
@testable import MLM

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
        #expect(r.vm.history.map(\.id) == [1, 2, 3, 4], "passed-over tracks move to History, never deleted")
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
        await waitUntil { !r.env.recordedMissing.isEmpty }
        #expect(r.env.recordedMissing == [2], "recordMissingAtUse (the monitor checks the folder is reachable)")
        #expect(r.vm.notice?.text == "Skipped “T2” — file missing")
        #expect(r.vm.notice?.action == .locate(gone))
    }

    /// Review B1: the disk being away is a wait, never a skip (DEC-014).
    @Test func nextWithTheDiskAwayKeepsTheQueueAndTheTrackThatPlays() async {
        let r = rig(root: true)
        // Sixty queued tracks on the library disk (relative paths); the current one plays from
        // this Mac.
        let onDisk = (Int64(10)..<70).map { id -> Track in
            var t = notDownloaded(id)
            t.organizedPath = "A/\(id).m4a"
            r.folder.file("A/\(id).m4a")
            return t
        }
        let current = local(9, r)
        await r.vm.playTrack(current, queue: [current] + onDisk)
        let queued = r.vm.upcoming
        r.env.offlineVolumePath = "/Volumes/Lexxar"  // unplugged
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 9, "the track that plays keeps playing")
        #expect(r.vm.isMainPlaying)
        #expect(r.vm.upcoming == queued, "nothing taken out of the queue")
        #expect(r.vm.notice?.text == "Can’t play — “Lexxar” is not connected.")
        #expect(r.env.recordedMissing.isEmpty && r.env.checkedFiles.isEmpty, "never a file problem")

        // The track ends while the disk is still away: the player names the waiting track.
        r.main.state = .stopped
        r.vm.trackDidEnd()
        await waitUntil { r.vm.cantPlay != nil }
        #expect(r.vm.currentTrack == nil)
        #expect(r.vm.cantPlay == CantPlayState(track: onDisk[0], reason: .driveNotConnected(volumeName: "Lexxar")))
        #expect(r.vm.upcoming == queued)
        #expect(r.vm.canResumeQueue)

        // Replugged: the state clears, Play continues with the first waiting track.
        r.env.offlineVolumePath = nil
        r.vm.reevaluateCantPlay(diskReturned: true)
        #expect(r.vm.cantPlay == nil)
        r.vm.togglePlayPause()
        await waitUntil { r.vm.currentTrack?.id == 10 }
        #expect(r.vm.currentTrack?.id == 10)
        #expect(r.vm.upcoming.count == queued.count - 1)
    }

    @Test func aDiskFoundAwayAtOpenTimeIsAWaitToo() async {
        let r = rig(root: true)
        // The persisted state still says connected; the file's own volume isn't there.
        var away = notDownloaded(2)
        away.organizedPath = "/Volumes/MLMTestsGone-\(UUID().uuidString)/2.m4a"
        let a = local(1, r)
        await r.vm.playTrack(a, queue: [a, away])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.upcoming.map(\.id) == [2], "still queued")
        #expect(r.env.recordedMissing.isEmpty)
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

    @Test func lookupTellsMissingFromDiskAwayWithTheMountCheck() {
        func probe(files: Set<String> = [], mounted: Set<String> = [], reachableRoots: Set<String> = []) -> PlaybackFileResolver.Probe {
            PlaybackFileResolver.Probe(fileExists: { files.contains($0) }, isVolumeMounted: { mounted.contains($0) },
                                       isLibraryRootReachable: { reachableRoots.contains($0) })
        }
        var t = notDownloaded(1)
        t.organizedPath = "/Volumes/Gone/a.m4a"
        // An empty leftover `/Volumes/Gone` folder is not a mounted disk (S2).
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: nil, probe: probe(files: ["/Volumes/Gone"]))
                == .driveNotConnected(volumePath: "/Volumes/Gone"))
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: nil, probe: probe(mounted: ["/Volumes/Gone"])) == .missing)
        t.organizedPath = "A/a.m4a"
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: "/Volumes/Lexxar/Music", probe: probe())
                == .driveNotConnected(volumePath: "/Volumes/Lexxar"))
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: "/Volumes/Lexxar/Music",
                                            probe: probe(mounted: ["/Volumes/Lexxar"], reachableRoots: ["/Volumes/Lexxar/Music"]))
                == .missing)
        t.organizedPath = nil
        #expect(PlaybackFileResolver.lookup(t, libraryRoot: "/x", probe: probe()) == .noFile)
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

    /// Review S8: a file that can't be opened never stops what plays.
    @Test func anUnreadableFileLeavesThePlayingTrackAlone() async {
        let r = rig()
        let a = local(1, r), bad = local(2, r)
        r.main.unreadable = [bad.organizedPath ?? ""]
        await r.vm.playTrack(a)
        await r.vm.playTrack(bad)
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.main.state == .playing)
        #expect(r.vm.notice?.text == "Couldn’t play “T2” — the file can’t be read")
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

    /// Review S8: Previous over a history entry that can't play drops it and goes on to the next
    /// earlier one; the track left still comes next.
    @Test func previousGoesOnPastAnUnavailableEntry() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        await r.vm.next()
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 3)
        r.folder.remove("2.m4a")
        r.main.currentPosition = 1
        await r.vm.back()
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.upcoming.first?.id == 3)
        #expect(r.vm.notice?.text == "Skipped “T2” — file missing")
    }

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
        #expect(r.vm.history.map(\.id) == [1], "a repeat adds no history entry (S9)")

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

    // MARK: Review S1 — a stale advance never wins over what the user did

    @Test func playingARowWhileAnAdvanceWaitsWins() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), x = local(9, r), y = local(10, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.env.freshGate.close()
        r.main.state = .stopped
        r.vm.trackDidEnd()                       // the advance waits inside its first await
        await waitUntil { r.env.freshGate.waiting == 1 }
        await r.vm.playTrack(x, queue: [x, y])   // the user double-clicks another row
        r.env.freshGate.open()
        await waitUntil { r.env.freshGate.waiting == 0 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.vm.currentTrack?.id == 9, "the stale advance gave up")
        #expect(r.vm.upcoming.map(\.id) == [10], "the new context stays")
    }

    @Test func stopWhileAnAdvanceWaitsStaysStopped() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.env.freshGate.close()
        let next = Task { await r.vm.next() }
        await waitUntil { r.env.freshGate.waiting == 1 }
        r.vm.stop()                              // ⌘.
        r.env.freshGate.open()
        await next.value
        #expect(r.vm.currentTrack == nil, "no track starts after Stop")
        #expect(r.main.loaded.count == 1)
    }

    @Test func aPreviewStartedWhileAnAdvanceWaitsIsNeverOverplayed() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), p = local(5, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.env.freshGate.close()
        let next = Task { await r.vm.next() }
        await waitUntil { r.env.freshGate.waiting == 1 }
        r.vm.preview.toggle(owner: "t", candidate: .previewable(p))
        r.env.freshGate.open()
        await next.value
        await waitUntil { r.vm.preview.isActive && !r.vm.preview.isLoading }
        #expect(r.vm.currentTrack?.id == 1, "the advance gave up")
        #expect(r.main.state != .playing, "never two audible sources")
    }

    @Test func anEndedTrackAdvanceDropsItselfWhenTheTrackChanged() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        r.env.freshGate.close()
        r.main.state = .stopped
        r.vm.trackDidEnd()
        await waitUntil { r.env.freshGate.waiting == 1 }
        let before = r.vm.generation
        let next = Task { await r.vm.next() }    // Next in the last moment of the track
        await waitUntil { r.vm.generation > before }
        r.env.freshGate.open()
        await next.value
        await waitUntil { r.env.freshGate.waiting == 0 }
        #expect(r.vm.currentTrack?.id == 2, "one advance, not two")
        #expect(r.vm.upcoming.map(\.id) == [3])
    }

    // MARK: Review S2 — a failing disk doesn't flag the whole context

    @Test func twoMissingFilesInARowStopAndHandTheJudgementToTheFileCheck() async {
        let r = rig()
        let a = local(1, r), g1 = local(2, r, exists: false), g2 = local(3, r, exists: false), g3 = local(4, r, exists: false)
        await r.vm.playTrack(a, queue: [a, g1, g2, g3])
        r.main.state = .stopped
        r.vm.trackDidEnd()
        await waitUntil { !r.env.checkedFiles.isEmpty }
        #expect(r.env.checkedFiles == [[2, 3]])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.env.recordedMissing.isEmpty, "nothing flagged by playback")
        #expect(r.vm.notice?.text == "Playback stopped — files on “Lexxar” can’t be read")
        #expect(r.vm.upcoming.map(\.id) == [2, 3, 4], "the unjudged tracks stay queued")
        #expect(r.vm.currentTrack == nil)
    }

    // MARK: Review nits

    @Test func aQueuedTrackWithoutAnIDDoesntEndTheRun() async {
        let r = rig()
        let a = local(1, r)
        var noID = local(2, r)
        noID.id = nil
        r.main.unreadable = [noID.organizedPath ?? ""]
        let c = local(3, r)
        await r.vm.playTrack(a, queue: [a, noID, c])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 3)
    }

    @Test func historyAndContextCapComeFromTheInjectedDefaults() async {
        let r = rig()
        r.env.defaults.set(2, forKey: "playback_history_size")
        r.env.defaults.set(1, forKey: "playback_context_cap")
        let tracks = (Int64(1)...4).map { local($0, r) }
        await r.vm.playTrack(tracks[0], queue: tracks)
        #expect(r.vm.upcoming.map(\.id) == [2])
        await r.vm.playTrack(tracks[2])
        await r.vm.playTrack(tracks[3])
        #expect(r.vm.history.map(\.id) == [3, 4])
    }

    @Test func aStuckCantPlayClearsWhenTheTrackBecomesPlayable() async {
        let r = rig()
        let b = notDownloaded(2)
        await r.vm.playTrack(b)
        #expect(r.vm.cantPlay?.reason == .notDownloaded)
        var downloaded = b
        downloaded.organizedPath = r.folder.file("2.m4a")
        r.env.fresh[2] = downloaded
        r.vm.reevaluateCantPlay(diskReturned: false)   // `.trackAvailabilityDidChange`
        await waitUntil { r.vm.cantPlay == nil }
        #expect(r.vm.cantPlay == nil)
    }
}
