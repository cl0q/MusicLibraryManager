import Foundation
import Testing
@testable import MLM

/// W2-C: the Space preview as a state machine driven through a fake audio port (DEC-009 as
/// revised by §10 Q1, DEC-010, DEC-047, UC-KEY-01/04/05/06). Lookups and the selection
/// debounce are answered by the test, so every ordering is deterministic — no clocks.
@Suite("PreviewControllerTests")
@MainActor
struct PreviewControllerTests {

    // MARK: Fakes

    @MainActor
    final class FakePort: PreviewAudioPort {
        var main = MainPlaybackSnapshot(trackID: 1, position: 72, wasPlaying: true)
        var mainIsPlaying = true
        var mainCanResume = true
        var log: [String] = []
        var previewPosition: TimeInterval = 0
        var previewDuration: TimeInterval = 240
        var failOpen: PreviewResolveFailure?
        var openedURLs: [URL] = []

        func captureMain() -> MainPlaybackSnapshot { main }
        func suspendMain() { log.append("suspendMain"); mainIsPlaying = false }
        func restoreMain(_ snapshot: MainPlaybackSnapshot) -> Bool {
            log.append("restoreMain(\(snapshot.wasPlaying))")
            guard mainCanResume else { return false }
            if snapshot.wasPlaying { mainIsPlaying = true }
            return true
        }
        func startPreview(_ resolved: ResolvedPreview) throws -> TimeInterval {
            if let failOpen { throw failOpen }
            openedURLs.append(resolved.url)
            let start = PreviewHotSpot.start(dropOffset: resolved.dropOffset, duration: previewDuration)
            previewPosition = start
            log.append("start(\(resolved.url.lastPathComponent)@\(Int(start)))")
            return start
        }
        func stopPreview() { log.append("stopPreview") }
        func pausePreview() { log.append("pausePreview") }
        func resumePreview() { log.append("resumePreview") }
        func seekPreview(by delta: TimeInterval) {
            previewPosition = min(max(previewPosition + delta, 0), previewDuration)
            log.append("seek(\(Int(delta)))")
        }
    }

    @MainActor
    final class Harness {
        let port = FakePort()
        var lookups: [(Track, (Result<ResolvedPreview, PreviewResolveFailure>) -> Void)] = []
        var timers: [() -> Void] = []
        var reports: [PlaybackWords.PreviewRefusal] = []
        var handOvers: [(Int64?, TimeInterval?)] = []
        var changes = 0
        var controller: PreviewController!

        init() {
            controller = PreviewController(
                port: port,
                resolve: { [unowned self] track, done in self.lookups.append((track, done)) },
                schedule: { [unowned self] _, work in self.timers.append(work) }
            )
            controller.onReport = { [unowned self] in self.reports.append($0) }
            controller.onHandOver = { [unowned self] track, position in self.handOvers.append((track.id, position)) }
            controller.onChange = { [unowned self] in self.changes += 1 }
        }

        /// Answer the oldest lookup with a file `‹id›.m4a`.
        func answerLookup(drop: TimeInterval? = nil) {
            guard !lookups.isEmpty else { return }
            let (track, done) = lookups.removeFirst()
            done(.success(ResolvedPreview(url: URL(fileURLWithPath: "/tmp/\(track.id ?? 0).m4a"), dropOffset: drop)))
        }

        func failLookup(_ failure: PreviewResolveFailure) {
            guard !lookups.isEmpty else { return }
            lookups.removeFirst().1(.failure(failure))
        }

        /// Fire every pending debounce.
        func settle() {
            let pending = timers
            timers = []
            pending.forEach { $0() }
        }
    }

    private func track(_ id: Int64, duration: Int = 240) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = "Artist/T\(id).m4a"
        t.duration = duration
        return t
    }

    private let table: PreviewOwner = "allTracks"

    // MARK: Start / end

    @Test func spaceStartsAtTheHotSpotAndPausesMain() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        #expect(h.controller.isActive && h.controller.isLoading)
        #expect(h.port.log == ["suspendMain"])
        h.answerLookup(drop: 95)
        #expect(h.port.log == ["suspendMain", "start(5.m4a@95)"])
        #expect(h.controller.hotSpot == 95)
        #expect(!h.controller.isLoading)
        #expect(h.controller.track?.id == 5)
    }

    @Test func spaceAgainEndsAndResumesMainAtItsPosition() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        #expect(!h.controller.isActive)
        #expect(h.port.log.suffix(2) == ["stopPreview", "restoreMain(true)"])
        #expect(h.port.mainIsPlaying)
    }

    @Test func escEndsAndIsOnlyUsedWhilePreviewing() {
        let h = Harness()
        #expect(h.controller.escape() == false, "Esc belongs to the next cancellable thing")
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        #expect(h.controller.escape() == true)
        #expect(!h.controller.isActive)
        #expect(h.port.log.last == "restoreMain(true)")
    }

    @Test func pausedMainStaysPausedAfterThePreview() {
        let h = Harness()
        h.port.main = MainPlaybackSnapshot(trackID: 1, position: 10, wasPlaying: false)
        h.port.mainIsPlaying = false
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.escape()
        #expect(h.port.log.last == "restoreMain(false)")
        #expect(!h.port.mainIsPlaying)
    }

    @Test func previewWhileNothingPlays() {
        let h = Harness()
        h.port.main = .nothing
        h.port.mainIsPlaying = false
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.toggle(owner: table, candidate: .nothing)
        #expect(!h.controller.isActive)
        #expect(!h.port.mainIsPlaying)
    }

    @Test func refusalsSayWhyAndLeavePlaybackAlone() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .refused(.notDownloaded))
        h.controller.toggle(owner: table, candidate: .refused(.notSingle))
        h.controller.toggle(owner: table, candidate: .nothing)
        #expect(h.reports == [.notDownloaded, .notSingle])
        #expect(h.port.log.isEmpty, "playback untouched")
        #expect(!h.controller.isActive)
    }

    @Test func theEndOfThePreviewedTrackResumesMain() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.previewDidFinish()
        #expect(!h.controller.isActive)
        #expect(h.port.log.suffix(2) == ["stopPreview", "restoreMain(true)"])
    }

    // MARK: Moving with the selection (debounced)

    @Test func arrowsMoveThePreviewAfterTheSelectionRests() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        // Key repeat: three rows in a row, then rest.
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(6)))
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(7)))
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(8)))
        #expect(h.lookups.isEmpty, "nothing reloads while the keys repeat")
        h.settle()
        #expect(h.lookups.map(\.0.id) == [8], "only the row the selection rested on loads")
        h.answerLookup()
        #expect(h.controller.track?.id == 8)
        #expect(h.port.openedURLs.map(\.lastPathComponent) == ["5.m4a", "8.m4a"])
        #expect(h.port.log.filter { $0 == "suspendMain" }.count == 1, "main is paused once")
        #expect(!h.port.log.contains { $0.hasPrefix("restoreMain") }, "main is not resumed between rows")
    }

    @Test func movingBackToThePreviewedRowCancelsThePendingSwitch() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(6)))
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(5)))
        h.settle()
        #expect(h.lookups.isEmpty)
        #expect(h.controller.track?.id == 5)
    }

    @Test func restingOnAnUnpreviewableRowEndsWithItsReason() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.selectionChanged(owner: table, candidate: .refused(.notDownloaded))
        h.settle()
        #expect(!h.controller.isActive)
        #expect(h.reports == [.notDownloaded])
        #expect(h.port.log.last == "restoreMain(true)")
    }

    @Test func clearingOrWideningTheSelectionEndsThePreview() {
        for candidate in [PreviewCandidate.nothing, .refused(.notSingle)] {
            let h = Harness()
            h.controller.toggle(owner: table, candidate: .previewable(track(5)))
            h.answerLookup()
            h.controller.selectionChanged(owner: table, candidate: candidate)
            h.settle()
            #expect(!h.controller.isActive)
        }
    }

    @Test func otherListsDontMoveThePreview() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.selectionChanged(owner: "playlist", candidate: .previewable(track(9)))
        #expect(h.timers.isEmpty)
        #expect(h.controller.track?.id == 5)
    }

    @Test func aLateLookupForAnOldRowIsIgnored() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        // Row 5's lookup is slow; the user moves on to 6 and it settles.
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(6)))
        h.settle()
        #expect(h.lookups.map(\.0.id) == [5, 6])
        h.answerLookup()  // 5 answers late
        #expect(h.port.openedURLs.isEmpty, "the stale answer opens nothing")
        h.answerLookup()  // 6
        #expect(h.port.openedURLs.map(\.lastPathComponent) == ["6.m4a"])
        #expect(h.controller.track?.id == 6)
    }

    // MARK: Rapid Space

    @Test func rapidSpaceNeverLeavesTwoPreviewsOrAPausedMain() {
        let h = Harness()
        for _ in 0..<5 {
            h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        }
        // 5 presses: start, end, start, end, start — one preview is loading.
        #expect(h.controller.isActive)
        #expect(h.lookups.count == 3)
        h.answerLookup(); h.answerLookup()
        #expect(h.port.openedURLs.isEmpty, "the first two lookups belong to ended previews")
        h.answerLookup()
        #expect(h.port.openedURLs.count == 1)
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        #expect(!h.controller.isActive)
        #expect(h.port.mainIsPlaying)
        #expect(h.port.log.filter { $0 == "suspendMain" }.count == 3)
        #expect(h.port.log.filter { $0 == "restoreMain(true)" }.count == 3)
    }

    @Test func spaceDuringAPendingMoveEndsThePreview() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(6)))
        h.controller.toggle(owner: table, candidate: .previewable(track(6)))
        h.settle()
        #expect(!h.controller.isActive)
        #expect(h.lookups.isEmpty)
    }

    // MARK: Seek, pause, Return

    @Test func arrowsSeekFiveSecondsOnlyWhilePreviewing() {
        let h = Harness()
        #expect(h.controller.seek(by: 5) == false, "outside a preview ←/→ belong to the table")
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        #expect(h.controller.seek(by: 5) == true, "loading: the key is still the preview's")
        h.answerLookup()
        #expect(h.controller.seek(by: PreviewController.seekStep))
        #expect(h.controller.seek(by: -PreviewController.seekStep))
        #expect(h.port.log.suffix(2) == ["seek(5)", "seek(-5)"])
    }

    @Test func playPauseDuringAPreviewPausesThePreviewNotMain() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.togglePause()
        #expect(h.controller.isPaused && h.controller.isActive)
        h.controller.togglePause()
        #expect(!h.controller.isPaused)
        #expect(h.port.log.suffix(2) == ["pausePreview", "resumePreview"])
        #expect(!h.port.mainIsPlaying)
    }

    @Test func returnPlaysThePreviewedTrackFromThePreviewedPosition() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup(drop: 80)
        h.controller.seek(by: 5)
        #expect(h.controller.handOver(track(5)))
        #expect(!h.controller.isActive)
        #expect(h.handOvers.count == 1)
        #expect(h.handOvers[0].0 == 5 && h.handOvers[0].1 == 85)
        #expect(!h.port.log.contains { $0.hasPrefix("restoreMain") }, "main is replaced, not resumed")
    }

    @Test func returnOnAnotherRowBeforeTheSwitchPlaysItFromTheStart() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.selectionChanged(owner: table, candidate: .previewable(track(6)))
        h.controller.handOver(track(6))
        #expect(h.handOvers.count == 1)
        #expect(h.handOvers[0].0 == 6 && h.handOvers[0].1 == nil)
        h.settle()
        #expect(h.lookups.isEmpty, "the pending switch died with the preview")
    }

    @Test func handOverWithoutAPreviewIsTheUsualActivation() {
        let h = Harness()
        #expect(h.controller.handOver(track(5)) == false)
        #expect(h.handOvers.isEmpty)
    }

    @Test func realPlaybackAbandonsThePreviewWithoutResumingMain() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.abandon()
        #expect(!h.controller.isActive)
        #expect(h.port.log.last == "stopPreview")
    }

    // MARK: Things going away

    @Test func aMissingPreviewFileEndsWithTheReasonAndResumesMain() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.failLookup(.fileMissing)
        #expect(!h.controller.isActive)
        #expect(h.reports == [.fileMissing])
        #expect(h.port.mainIsPlaying)
    }

    @Test func aFileThatCantBeOpenedEndsThePreview() {
        let h = Harness()
        h.port.failOpen = .unreadable
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        #expect(!h.controller.isActive)
        #expect(h.reports == [.unreadable])
        #expect(h.port.log.last == "restoreMain(true)")
    }

    @Test func mainsFileGoneMeanwhileIsNotResumed() {
        let h = Harness()
        h.port.mainCanResume = false
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.escape()
        #expect(!h.controller.isActive)
        #expect(!h.port.mainIsPlaying, "the main player stays stopped and says why itself")
    }

    @Test func driveUnmountDuringAPreviewEndsItWithoutResumingMain() {
        let h = Harness()
        h.controller.toggle(owner: table, candidate: .previewable(track(5)))
        h.answerLookup()
        h.controller.end(resumeMain: false)
        #expect(!h.controller.isActive)
        #expect(h.port.log.suffix(2) == ["stopPreview", "restoreMain(false)"])
        #expect(!h.port.mainIsPlaying, "main's file is most likely on the same disk")
    }

    // MARK: Pieces

    @Test func hotSpotRule() {
        #expect(PreviewHotSpot.start(dropOffset: 95, duration: 240) == 95)
        #expect(PreviewHotSpot.start(dropOffset: nil, duration: 240) == 30)
        #expect(PreviewHotSpot.start(dropOffset: 0, duration: 240) == 30, "0 means no drop was found")
        #expect(PreviewHotSpot.start(dropOffset: 300, duration: 240) == 30, "a drop past the end is ignored")
        #expect(PreviewHotSpot.start(dropOffset: nil, duration: 40) == 10, "short tracks start at a quarter")
        #expect(PreviewHotSpot.start(dropOffset: nil, duration: 0) == 0)
    }

    @Test func candidatesFromRows() {
        func row(_ id: Int64, _ change: (inout Track) -> Void = { _ in }) -> TrackRow {
            var t = track(id)
            change(&t)
            return TrackRowBuilder.build([t])[0]
        }
        let offline = TrackTableLiveState(offlineVolumePath: "/Volumes/Lexxar", offlineVolumeName: "Lexxar")
        #expect(PreviewCandidate.make(rows: [], live: .idle) == .nothing)
        #expect(PreviewCandidate.make(rows: [row(1), row(2)], live: .idle) == .refused(.notSingle))
        #expect(PreviewCandidate.make(rows: [row(1)], live: .idle) == .previewable(row(1).track))
        #expect(PreviewCandidate.make(rows: [row(1)], live: offline) == .refused(.driveNotConnected(volumeName: "Lexxar")))
        #expect(PreviewCandidate.make(rows: [row(1) { $0.organizedPath = nil }], live: .idle) == .refused(.notDownloaded))
        #expect(PreviewCandidate.make(rows: [row(1) { $0.fileMissingSince = "2026-10-05T10:00:00Z" }], live: .idle) == .refused(.fileMissing))
        #expect(PreviewCandidate.make(rows: [row(1) { $0.fileMissingSince = "2026-10-05T10:00:00Z" }], live: offline)
                == .refused(.driveNotConnected(volumeName: "Lexxar")), "never File missing because of the drive")
    }
}
