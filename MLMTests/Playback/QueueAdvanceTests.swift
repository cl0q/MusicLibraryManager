import Foundation
import Testing
@testable import MLM

/// W2-C: the one queue-advance decision (DEC-045, UC-TB-09, PP-MAIN-01 — the queue never
/// stalls on an unplayable track). Pure: verdicts come from a table, nothing touches the disk.
@Suite("QueueAdvanceTests")
struct QueueAdvanceTests {

    private func track(_ id: Int64) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = "Artist/T\(id).m4a"
        return t
    }

    private func queue(context ids: [Int64], playNext: [Int64] = [], started: Int64? = nil) -> PlaybackQueue {
        var q = PlaybackQueue()
        if let started {
            q.startContext(track(started), following: ids.map(track), cap: 100)
        } else {
            q.replaceContext(ids.map(track), cap: 100)
        }
        if !playNext.isEmpty { q.insertPlayNext(playNext.map(track)) }
        return q
    }

    /// Verdicts by id; unknown ids are playable.
    private func verdicts(_ table: [Int64: PlaybackPlayability]) -> (Track) -> PlaybackPlayability {
        { table[$0.id ?? -1] ?? .playable }
    }

    // MARK: Next / auto-advance

    @Test func nextPlaysTheFirstPlayableAndSkipsUnplayableInTheMiddle() {
        let result = QueueAdvance.next(
            queue: queue(context: [2, 3, 4]), current: track(1), repeatMode: .off, trigger: .userNext,
            playability: verdicts([2: .notDownloaded, 3: .fileMissing]))
        #expect(result.track?.id == 4)
        #expect(result.skipped.map(\.track.id) == [2, 3])
        #expect(result.skipped.map(\.reason) == [.notDownloaded, .fileMissing])
        #expect(result.queue.upcoming.isEmpty)
    }

    @Test func unplayableAtTheStartIsSkipped() {
        let result = QueueAdvance.next(
            queue: queue(context: [2, 3]), current: nil, repeatMode: .off, trigger: .userNext,
            playability: verdicts([2: .notDownloaded]))
        #expect(result.track?.id == 3)
        #expect(result.skipped.map(\.reason) == [.notDownloaded])
        #expect(result.waitingForDrive == nil)
    }

    /// Review B1 (DEC-014): the disk being away is a wait, never a skip.
    @Test func aTrackOnADiskThatIsAwayIsAWaitNotASkip() {
        let q = queue(context: [2, 3, 4], playNext: [9])
        for trigger in [QueueAdvance.Trigger.userNext, .trackEnded] {
            // (Repeat One at the end of a track replays the current one — no queue involved.)
            for mode in PlaybackRepeatMode.allCases where !(mode == .one && trigger == .trackEnded) {
                let result = QueueAdvance.next(
                    queue: q, current: track(1), repeatMode: mode, trigger: trigger,
                    playability: verdicts([9: .notDownloaded, 2: .driveNotConnected]))
                #expect(result.track == nil, "\(trigger) \(mode)")
                #expect(result.waitingForDrive?.id == 2)
                #expect(result.queue == q, "nothing consumed — not even the item passed before it")
                #expect(result.skipped.isEmpty)
            }
        }
    }

    @Test func unplayableAtTheEndStopsWithTheSkipsReported() {
        let result = QueueAdvance.next(
            queue: queue(context: [2, 3]), current: track(1), repeatMode: .off, trigger: .trackEnded,
            playability: verdicts([2: .notDownloaded, 3: .notDownloaded]))
        #expect(result.track == nil)
        #expect(result.skipped.count == 2)
        #expect(result.queue.upcoming.isEmpty, "skipped items are consumed — Next never retries them")
    }

    @Test func allUnplayableNeverLoops() {
        let ids = Array(Int64(2)...Int64(60))
        var table: [Int64: PlaybackPlayability] = [:]
        for id in ids { table[id] = .notDownloaded }
        for mode in PlaybackRepeatMode.allCases {
            let result = QueueAdvance.next(
                queue: queue(context: ids, started: 1), current: track(1), repeatMode: mode, trigger: .userNext,
                playability: verdicts(table.merging([1: .fileMissing]) { $1 }))
            #expect(result.track == nil, "\(mode)")
            // Repeat All looks at the cycle (which also holds the started track) once more.
            let expected = mode == .all ? ids.count + 1 : ids.count
            #expect(result.skipped.count == expected, "\(mode): each item reported once")
        }
    }

    @Test func emptyQueueEndsWithoutSkips() {
        let result = QueueAdvance.next(queue: PlaybackQueue(), current: track(1), repeatMode: .off,
                                       trigger: .trackEnded, playability: verdicts([:]))
        #expect(result.track == nil)
        #expect(result.skipped.isEmpty)
    }

    @Test func playNextItemsComeFirstAndAreSkippedToo() {
        let result = QueueAdvance.next(
            queue: queue(context: [5, 6], playNext: [3, 4]), current: track(1), repeatMode: .off, trigger: .userNext,
            playability: verdicts([3: .notDownloaded]))
        #expect(result.track?.id == 4)
        #expect(result.queue.upcoming.map(\.id) == [5, 6])
    }

    // MARK: Repeat

    @Test func repeatOneReplaysTheEndedTrackButNextMovesOn() {
        let q = queue(context: [2, 3], started: 1)
        let ended = QueueAdvance.next(queue: q, current: track(1), repeatMode: .one, trigger: .trackEnded,
                                      playability: verdicts([:]))
        #expect(ended.track?.id == 1)
        #expect(ended.repeatsCurrent)
        #expect(ended.queue == q)
        let next = QueueAdvance.next(queue: q, current: track(1), repeatMode: .one, trigger: .userNext,
                                     playability: verdicts([:]))
        #expect(next.track?.id == 2)
    }

    @Test func repeatOneWithAMissingCurrentFileMovesOn() {
        let result = QueueAdvance.next(queue: queue(context: [2], started: 1), current: track(1), repeatMode: .one,
                                       trigger: .trackEnded, playability: verdicts([1: .fileMissing]))
        #expect(result.track?.id == 2)
    }

    @Test func repeatAllStartsTheCycleAgain() {
        var q = queue(context: [2, 3], started: 1)
        q.advance(); q.advance()  // 2 and 3 played; queue empty
        let result = QueueAdvance.next(queue: q, current: track(3), repeatMode: .all, trigger: .trackEnded,
                                       playability: verdicts([:]))
        #expect(result.track?.id == 1)
        #expect(result.queue.upcoming.map(\.id) == [2, 3])
    }

    @Test func repeatAllSkipsUnplayableInTheNewCycle() {
        var q = queue(context: [2, 3], started: 1)
        q.advance(); q.advance()
        let result = QueueAdvance.next(queue: q, current: track(3), repeatMode: .all, trigger: .userNext,
                                       playability: verdicts([1: .notDownloaded]))
        #expect(result.track?.id == 2)
        #expect(result.skipped.map(\.track.id) == [1])
    }

    @Test func repeatOffEndsAtTheEnd() {
        var q = queue(context: [2], started: 1)
        q.advance()
        let result = QueueAdvance.next(queue: q, current: track(2), repeatMode: .off, trigger: .trackEnded,
                                       playability: verdicts([:]))
        #expect(result.track == nil)
    }

    // MARK: Shuffle (a shuffled list is a context like any other)

    @Test func shuffledContextAdvancesInItsOwnOrderSkippingUnplayable() {
        let order: [Int64] = [7, 3, 9, 1]
        var q = PlaybackQueue()
        q.startContext(track(5), following: order.map(track), cap: 100)
        let result = QueueAdvance.next(queue: q, current: track(5), repeatMode: .off, trigger: .trackEnded,
                                       playability: verdicts([7: .notDownloaded]))
        #expect(result.track?.id == 3)
        #expect(result.queue.upcoming.map(\.id) == [9, 1])
    }

    // MARK: Previous (UC-TB-09)

    @Test func previousRestartsAfterMoreThanThreeSeconds() {
        let decision = QueueAdvance.previous(history: [track(1), track(2)], current: track(2), position: 3.5,
                                             playability: verdicts([:]))
        #expect(decision == .restartCurrent(skipped: []))
    }

    @Test func previousGoesBackWithinThreeSeconds() {
        let decision = QueueAdvance.previous(history: [track(1), track(2)], current: track(2), position: 3.0,
                                             playability: verdicts([:]))
        #expect(decision == .play(track(1), history: [], skipped: []))
    }

    @Test func previousPassesOverTracksThatCantPlayNow() {
        let decision = QueueAdvance.previous(history: [track(1), track(2), track(3)], current: track(3), position: 0,
                                             playability: verdicts([2: .fileMissing]))
        #expect(decision == .play(track(1), history: [], skipped: [SkippedTrack(track: track(2), reason: .fileMissing)]))
    }

    @Test func previousWaitsForADiskThatIsAway() {
        let decision = QueueAdvance.previous(history: [track(1), track(2), track(3)], current: track(3), position: 0,
                                             playability: verdicts([2: .driveNotConnected]))
        #expect(decision == .waitingForDrive(track(2)))
    }

    /// Review S9: Previous drops every trailing entry of the current track.
    @Test func previousDropsTrailingEntriesOfTheCurrentTrack() {
        let decision = QueueAdvance.previous(history: [track(1), track(2), track(2), track(2)], current: track(2), position: 0,
                                             playability: verdicts([:]))
        #expect(decision == .play(track(1), history: [], skipped: []))
    }

    @Test func previousWithNothingPlayableRestarts() {
        let decision = QueueAdvance.previous(history: [track(1), track(2)], current: track(2), position: 1,
                                             playability: verdicts([1: .fileMissing]))
        #expect(decision == .restartCurrent(skipped: [SkippedTrack(track: track(1), reason: .fileMissing)]))
    }

    // MARK: Start (play a row, the following rows are the context)

    @Test func startUsesTheRowsAfterTheChosenOneAndKeepsPlayNext() {
        var q = PlaybackQueue()
        q.insertPlayNext([track(9)])
        let started = QueueAdvance.start(track(2), in: [1, 2, 3, 4].map(track), queue: q, cap: 2)
        #expect(started.upcoming.map(\.id) == [9, 3, 4])
        #expect(started.cycle.map(\.id) == [2, 3, 4])
    }

    // MARK: Verdicts from persisted state (no disk)

    @Test func playabilityComesFromPersistedStateAndTheDrive() {
        var local = track(1)
        #expect(PlaybackPlayability.of(local, offlineVolumePath: nil) == .playable)
        #expect(PlaybackPlayability.of(local, offlineVolumePath: "/Volumes/Lexxar") == .driveNotConnected)
        local.organizedPath = "/Volumes/Other/a.m4a"
        #expect(PlaybackPlayability.of(local, offlineVolumePath: "/Volumes/Lexxar") == .playable)
        var missing = track(2)
        missing.fileMissingSince = "2026-10-05T10:00:00Z"
        #expect(PlaybackPlayability.of(missing, offlineVolumePath: nil) == .fileMissing)
        #expect(PlaybackPlayability.of(missing, offlineVolumePath: "/Volumes/Lexxar") == .driveNotConnected,
                "an unplugged drive is never a file problem (DEC-014)")
        var remote = track(3)
        remote.organizedPath = nil
        #expect(PlaybackPlayability.of(remote, offlineVolumePath: nil) == .notDownloaded)
        #expect(PlaybackPlayability.of(remote, offlineVolumePath: "/Volumes/Lexxar") == .notDownloaded)
    }

    // MARK: Words

    @Test func skipNotesUseTheDesignedShapes() {
        let nd = [SkippedTrack(track: track(1), reason: .notDownloaded), SkippedTrack(track: track(2), reason: .notDownloaded)]
        #expect(PlaybackWords.skipNote(nd, volumeName: nil)
                == .init(text: "Skipped 2 tracks that aren’t downloaded", action: .download(trackIDs: [1, 2])))
        #expect(PlaybackWords.skipNote(Array(nd.prefix(1)), volumeName: nil)?.text == "Skipped 1 track that isn’t downloaded")
        let missing = [SkippedTrack(track: track(4), reason: .fileMissing)]
        #expect(PlaybackWords.skipNote(missing, volumeName: nil) == .init(text: "Skipped “T4” — file missing", action: .locate(trackID: 4)))
        let drive = [SkippedTrack(track: track(5), reason: .driveNotConnected)]
        #expect(PlaybackWords.skipNote(drive, volumeName: "Lexxar")?.text == "Skipped 1 track — “Lexxar” is not connected")
        let mixed = nd + missing
        #expect(PlaybackWords.skipNote(mixed, volumeName: nil) == .init(text: "Skipped 3 tracks that can’t play", action: .download(trackIDs: [1, 2])))
        #expect(PlaybackWords.skipNote([], volumeName: nil) == nil)
    }

    @Test func playerAndPreviewSentencesAreVerbatim() {
        #expect(PlaybackWords.notPlaying == "Not playing")
        #expect(PlaybackWords.previewHint == "Space to stop · Return to play")
        #expect(PlaybackWords.previewTag(fromSource: "YouTube") == "Preview · from YouTube")
        #expect(PlaybackWords.CantPlay.notDownloaded.playerSentence == "Can’t play — not downloaded")
        #expect(PlaybackWords.CantPlay.notDownloaded.fixTitle == "Download")
        #expect(PlaybackWords.CantPlay.fileMissing.playerSentence == "Can’t play — file missing")
        #expect(PlaybackWords.CantPlay.fileMissing.fixTitle == "Locate…")
        #expect(PlaybackWords.CantPlay.driveNotConnected(volumeName: "Lexxar").playerSentence == "Can’t play — “Lexxar” is not connected")
        #expect(PlaybackWords.CantPlay.driveNotConnected(volumeName: "Lexxar").fixTitle == nil)
        #expect(PlaybackWords.PreviewRefusal.notSingle.message == "Space previews one track. Select a single track.")
        #expect(PlaybackWords.PreviewRefusal.notDownloaded.message == "Can’t preview — not downloaded. Press ⌘D to download.")
        #expect(PlaybackWords.PreviewRefusal.fileMissing.message == "Can’t preview — file missing.")
        #expect(PlaybackWords.PreviewRefusal.driveNotConnected(volumeName: "Lexxar").message == "Can’t preview — “Lexxar” is not connected.")
        #expect(PlaybackWords.cantPlayDriveMessage("Lexxar") == "Can’t play — “Lexxar” is not connected.")
        #expect(PlaybackWords.disconnectedPaused("Lexxar", at: "1:12") == "“Lexxar” was disconnected — playback paused at 1:12.")
        #expect(PlaybackWords.time(72) == "1:12")
        #expect(PlaybackWords.time(3_725) == "1:02:05")
    }
}
