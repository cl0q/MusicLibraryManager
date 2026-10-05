import Foundation
import MediaPlayer
import Testing
@testable import MLM

/// W2-C: the preview through the real view model with silent fake players — the main track
/// pauses and resumes where it was, the queue and history never change, Now Playing follows
/// the preview, Return hands over, things disappearing meanwhile.
@Suite("PlaybackPreviewTests")
@MainActor
struct PlaybackPreviewTests {

    @MainActor
    final class Timers {
        var pending: [@MainActor () -> Void] = []
        func fire() { let all = pending; pending = []; all.forEach { $0() } }
    }

    struct Rig {
        let vm: PlaybackViewModel
        let main: SilentAudioPlayer
        let preview: SilentAudioPlayer
        let env: PlaybackTestEnvironment
        let folder: PlaybackFixtureFolder
        let timers: Timers
    }

    private func rig() -> Rig {
        let folder = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment()
        let main = SilentAudioPlayer()
        let preview = SilentAudioPlayer()
        preview.duration = 240
        let timers = Timers()
        let vm = PlaybackViewModel(audioPlayer: main, environment: env.environment, previewPlayer: { preview },
                                   previewSchedule: { _, work in timers.pending.append(work) })
        return Rig(vm: vm, main: main, preview: preview, env: env, folder: folder, timers: timers)
    }

    private func local(_ id: Int64, _ rig: Rig) -> Track {
        var t = Track(artist: "Artist \(id)", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = rig.folder.file("\(id).m4a")
        t.duration = 240
        return t
    }

    private let owner: PreviewOwner = "table"

    /// Start a preview and wait until its audio runs (the lookup is asynchronous).
    private func startPreview(_ track: Track, _ r: Rig) async {
        r.vm.preview.toggle(owner: owner, candidate: .previewable(track))
        await waitUntil { r.vm.preview.isActive && !r.vm.preview.isLoading }
    }

    @Test func previewPausesMainAndResumesItWhereItWas() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, c])
        r.main.currentPosition = 72
        let queueBefore = r.vm.upcoming
        let historyBefore = r.vm.history

        await startPreview(b, r)
        #expect(r.main.state == .paused)
        #expect(r.preview.loaded.map(\.lastPathComponent) == ["2.m4a"])
        #expect(r.preview.state == .playing)
        #expect(r.vm.currentTrack?.id == 1, "the main track stays loaded")
        #expect(r.vm.isPlaying, "something is audible")
        #expect(!r.vm.isMainPlaying)

        #expect(r.vm.preview.escape())
        #expect(!r.vm.preview.isActive)
        #expect(r.preview.state == .stopped)
        #expect(r.main.state == .playing)
        #expect(r.main.currentPosition == 72)
        #expect(r.vm.upcoming == queueBefore, "the queue is untouched by previews")
        #expect(r.vm.history == historyBefore, "history is not polluted")
    }

    @Test func pausedMainStaysPausedAfterThePreview() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        r.vm.pause()
        await startPreview(b, r)
        r.vm.preview.escape()
        #expect(r.main.state == .paused)
    }

    @Test func theHotSpotIsTheAnalysedDropElseHalfAMinute() async {
        let r = rig()
        let b = local(2, r), c = local(3, r)
        r.env.drops[2] = 95
        await startPreview(b, r)
        #expect(r.preview.seeks == [95])
        #expect(r.vm.preview.hotSpot == 95)
        r.vm.preview.escape()
        await startPreview(c, r)
        #expect(r.preview.seeks.last == 30)
    }

    @Test func nowPlayingShowsThePreviewThenTheMainTrack() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        #expect(r.vm.nowPlaying?.title == "T1")
        await startPreview(b, r)
        #expect(r.vm.nowPlaying?.title == "T2")
        #expect(r.vm.nowPlaying?.isPlaying == true)
        #expect(r.vm.nowPlaying?.duration == 240)
        r.vm.preview.escape()
        #expect(r.vm.nowPlaying?.title == "T1")
        let info = RemoteCommandService.info(for: try! #require(r.vm.nowPlaying))
        #expect(info[MPMediaItemPropertyTitle] as? String == "T1")
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
    }

    @Test func playPauseDuringAPreviewPausesThePreviewOnly() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        await startPreview(b, r)
        r.vm.togglePlayPause()  // media key, toolbar, Playback menu, Dock
        #expect(r.preview.state == .paused)
        #expect(r.vm.preview.isActive && r.vm.preview.isPaused)
        #expect(!r.vm.isPlaying)
        #expect(r.main.state == .paused)
        r.vm.togglePlayPause()
        #expect(r.preview.state == .playing)
    }

    @Test func arrowsSeekThePreview() async {
        let r = rig()
        let b = local(2, r)
        await startPreview(b, r)
        #expect(r.vm.preview.seek(by: PreviewController.seekStep))
        #expect(r.preview.currentPosition == 35)
        #expect(r.vm.preview.seek(by: -PreviewController.seekStep))
        #expect(r.preview.currentPosition == 30)
    }

    @Test func returnPlaysThePreviewedTrackForRealFromThePreviewedPosition() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a)
        await startPreview(b, r)
        r.preview.currentPosition = 101
        // The table: hand over, then its usual activation with the following rows.
        r.vm.preview.handOver(b)
        await r.vm.playTrack(b, queue: [a, b, c])
        #expect(!r.vm.preview.isActive)
        #expect(r.vm.currentTrack?.id == 2)
        #expect(r.main.seeks.last == 101)
        #expect(r.vm.upcoming.map(\.id) == [3], "the rows after it become the queue")
        #expect(r.vm.history.map(\.id) == [1, 2])
    }

    @Test func movingTheSelectionMovesThePreviewAfterTheDebounce() async {
        let r = rig()
        let b = local(2, r), c = local(3, r)
        await startPreview(b, r)
        r.vm.preview.selectionChanged(owner: owner, candidate: .previewable(c))
        #expect(r.preview.loaded.count == 1)
        r.timers.fire()
        await waitUntil { r.preview.loaded.count == 2 }
        #expect(r.vm.preview.track?.id == 3)
    }

    @Test func aPreviewFileThatIsGoneSaysSoAndLeavesPlaybackAlone() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        r.folder.remove("2.m4a")
        r.vm.preview.toggle(owner: owner, candidate: .previewable(b))
        await waitUntil { !r.vm.preview.isActive }
        #expect(r.vm.notice?.text == "Can’t preview — file missing.")
        #expect(r.env.recordedMissing == [2])
        #expect(r.main.state == .playing, "main resumes at once")
    }

    @Test func mainsFileGoneDuringThePreviewIsNotResumed() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        await startPreview(b, r)
        r.folder.remove("1.m4a")
        r.vm.preview.escape()
        #expect(r.vm.currentTrack == nil)
        #expect(r.vm.cantPlay == CantPlayState(track: a, reason: .fileMissing))
        await waitUntil { !r.env.recordedMissing.isEmpty }
        #expect(r.env.recordedMissing == [1])
    }

    @Test func theLibraryDiskGoingAwayEndsThePreviewAndLeavesMainPaused() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        await startPreview(b, r)
        // What the window's one drive handler calls on `.libraryDriveDidUnmount`.
        #expect(r.vm.endPreviewForDiskLoss() == true, "main was playing under the preview: the window says so")
        #expect(!r.vm.preview.isActive)
        #expect(r.preview.state == .stopped)
        #expect(r.main.state == .paused)
        #expect(r.vm.currentTrack?.id == 1)
    }

    @Test func realPlaybackAbandonsThePreview() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, c])
        await startPreview(b, r)
        await r.vm.next()
        #expect(!r.vm.preview.isActive)
        #expect(r.preview.state == .stopped)
        #expect(r.vm.currentTrack?.id == 3)
    }

    @Test func previewWhileNothingPlaysAndStopAfterwards() async {
        let r = rig()
        let b = local(2, r)
        await startPreview(b, r)
        #expect(r.vm.isPlaying)
        #expect(!r.vm.hasTrack)
        r.vm.stop()  // ⌘.
        #expect(!r.vm.preview.isActive)
        #expect(r.vm.nowPlaying == nil)
    }

    // MARK: Review round

    @Test func thePreviewPlayersEngineIsReleasedAfterThePreview() async {
        let r = rig()
        let b = local(2, r)
        await startPreview(b, r)
        #expect(r.vm.hasPreviewPlayer)
        r.vm.preview.escape()
        r.timers.fire()   // the release delay (S3)
        #expect(!r.vm.hasPreviewPlayer)
        await startPreview(b, r)
        #expect(r.vm.hasPreviewPlayer, "a new preview makes a new one")
    }

    @Test func stopDuringAPreviewEndsOnlyThePreview() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a)
        await startPreview(b, r)
        r.vm.stop()   // ⌘.
        #expect(!r.vm.preview.isActive)
        #expect(r.vm.currentTrack?.id == 1 && r.main.state == .paused, "main stays loaded and paused")
        r.vm.stop()
        #expect(r.vm.currentTrack == nil)
    }

    @Test func aFailedPlayDuringAPreviewEndsThePreviewAndResumesMain() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        var gone = local(3, r)
        gone.organizedPath = r.folder.url.appendingPathComponent("gone.m4a").path
        await r.vm.playTrack(a)
        await startPreview(b, r)
        await r.vm.playTrack(gone)
        #expect(!r.vm.preview.isActive)
        #expect(r.vm.currentTrack?.id == 1 && r.main.state == .playing)
    }

    @Test func previewingATrackWithoutAFileSaysNotDownloaded() async {
        let r = rig()
        var remote = local(4, r)
        remote.organizedPath = nil
        r.vm.preview.toggle(owner: owner, candidate: .previewable(remote))
        await waitUntil { !r.vm.preview.isActive }
        #expect(r.vm.notice?.text == "Can’t preview — not downloaded. Press ⌘D to download.")
    }

    /// Review nit: Space within one tick of the main track's natural end — after the preview the
    /// queue advances; the ended track doesn't restart from 0.
    @Test func aTrackThatEndedJustBeforeThePreviewAdvancesAfterIt() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), p = local(5, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.env.freshGate.close()
        r.main.state = .stopped
        r.vm.trackDidEnd()
        await waitUntil { r.env.freshGate.waiting == 1 }
        await startPreview(p, r)
        r.env.freshGate.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.vm.currentTrack?.id == 1, "nothing advanced under the preview")
        r.vm.preview.escape()
        await waitUntil { r.vm.currentTrack?.id == 2 }
        #expect(r.vm.currentTrack?.id == 2)
        #expect(!r.main.seeks.contains(0))
    }
}
