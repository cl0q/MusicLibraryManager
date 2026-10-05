import Foundation
import Testing
@testable import MLM

/// W2-D: the queue editing API of `PlaybackViewModel` — serialised with the transport chain,
/// IMP-033 kept, entry identities through jumps and History, previews never touch the queue.
@Suite("PlaybackViewModelQueueEditingTests")
@MainActor
struct PlaybackViewModelQueueEditingTests {
    struct Rig {
        let vm: PlaybackViewModel
        let main: SilentAudioPlayer
        let preview: SilentAudioPlayer
        let env: PlaybackTestEnvironment
        let folder: PlaybackFixtureFolder
    }

    private func rig() -> Rig {
        let folder = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment()
        let main = SilentAudioPlayer()
        let preview = SilentAudioPlayer()
        let vm = PlaybackViewModel(audioPlayer: main, environment: env.environment, previewPlayer: { preview },
                                   previewSchedule: { _, _ in })
        return Rig(vm: vm, main: main, preview: preview, env: env, folder: folder)
    }

    private func local(_ id: Int64, _ rig: Rig) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = rig.folder.file("\(id).m4a")
        t.duration = 200
        return t
    }

    private func notDownloaded(_ id: Int64) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        return t
    }

    private func nextIDs(_ vm: PlaybackViewModel) -> [Int64?] { vm.queueSnapshot.upcoming.map(\.id) }

    // MARK: Lanes

    @Test func playNextAndAddToQueueLandWhereTheDesignSays() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), x = local(8, r), y = local(9, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        let added = r.vm.addToQueue([x])
        #expect(added?.kind == .addToQueue)
        r.vm.playNext([y])
        #expect(r.vm.queueSnapshot.playNext.map(\.id) == [9, 8])
        #expect(r.vm.queueSnapshot.context.map(\.id) == [2, 3])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 9)
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 8)
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 2)
    }

    @Test func theSameTrackTwiceIsTwoRowsEverywhere() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.vm.playNext([b])
        let entries = r.vm.queueSnapshot.upcomingEntries
        #expect(entries.map(\.track.id) == [2, 2])
        #expect(entries[0].id != entries[1].id)
        r.vm.removeEntries([entries[1].id])
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == [entries[0].id])
        // Played twice: two History rows with their own ids.
        await r.vm.playTrack(a)
        #expect(r.vm.history.map(\.id) == [1, 1])
        #expect(Set(r.vm.historyEntries.map(\.id)).count == 2)
    }

    // MARK: Edits never wait behind an advance (W2-D review: transport stalls)

    @Test func anEditAppliesAtOnceWhileAnAdvanceWaitsAndSurvivesItsCommit() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), d = local(4, r), e = local(5, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        r.env.freshGate.close()
        let advancing = Task { await r.vm.next() }
        await waitUntil { r.env.freshGate.waiting == 1 }
        // The advance waits (a slow lookup); the edit doesn't wait for it.
        let receipt = r.vm.playNext([e])
        #expect(receipt != nil)
        #expect(nextIDs(r.vm) == [5, 2, 3, 4], "applied at once")
        r.env.freshGate.open()
        await advancing.value
        // The advance took the head it had chosen (2) and rebased: the edit stays.
        #expect(r.vm.currentTrack?.id == 2)
        #expect(nextIDs(r.vm) == [5, 3, 4], "nothing lost")
    }

    @Test func aRemoveRacingAnAdvanceStaysRemoved() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), d = local(4, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        let cEntry = r.vm.queueSnapshot.contextEntries[1].id
        r.env.freshGate.close()
        let advancing = Task { await r.vm.next() }
        await waitUntil { r.env.freshGate.waiting == 1 }
        r.vm.removeEntries([cEntry])
        #expect(nextIDs(r.vm) == [2, 4])
        r.env.freshGate.open()
        await advancing.value
        #expect(r.vm.currentTrack?.id == 2)
        #expect(nextIDs(r.vm) == [4])
    }

    @Test func undoAndRedoDontWaitBehindAStuckAdvance() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), x = local(9, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.env.freshGate.close()
        let advancing = Task { await r.vm.next() }
        await waitUntil { r.env.freshGate.waiting == 1 }
        let receipt = r.vm.playNext([x])!
        #expect(r.vm.revertQueueEdit(receipt))
        #expect(nextIDs(r.vm) == [2])
        #expect(r.vm.reapplyQueueEdit(receipt))
        #expect(nextIDs(r.vm) == [9, 2])
        r.env.freshGate.open()
        await advancing.value
        #expect(r.vm.currentTrack?.id == 2)
        #expect(nextIDs(r.vm) == [9])
    }

    @Test func theRebaseKeepsEveryEditAndOnlyTakesWhatTheAdvanceTook() {
        func entry(_ id: Int64) -> QueueEntry {
            var t = Track(artist: "A", album: "B", title: "T\(id)", format: "m4a", originalPath: "x://\(id)")
            t.id = id
            return QueueEntry(track: t)
        }
        let e1 = entry(1), e2 = entry(2), e3 = entry(3), x = entry(9)
        let start = PlaybackQueue(playNext: [], context: [e1, e2, e3])
        let target = PlaybackQueue(playNext: [], context: [e2, e3])  // the advance took e1
        // Meanwhile: Play Next x, and e3 removed.
        let current = PlaybackQueue(playNext: [x], context: [e1, e2])
        let rebased = PlaybackQueue.rebase(current, from: start, to: target)
        #expect(rebased.playNextEntries == [x])
        #expect(rebased.contextEntries == [e2])
        #expect(PlaybackQueue.rebase(start, from: start, to: target) == target, "nothing edited: exactly the target")
    }

    // MARK: IMP-033 with edits

    @Test func aQueuedTrackThatCantPlayIsPassedIntoHistoryNeverDeleted() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), missing = notDownloaded(7)
        await r.vm.playTrack(a, queue: [a, b])
        r.vm.playNext([missing])
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 2)
        #expect(r.vm.history.map(\.id) == [1, 7, 2], "passed over into History, before the one that plays")
        #expect(r.vm.notice?.text.hasPrefix("Skipped") == true)
    }

    @Test func withTheDiskAwayNothingLeavesTheQueueAndEditsStillWork() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        r.env.offlineVolumePath = "/Volumes/Lexxar"
        // Every queued file is on the disk that went away.
        var away = b
        away.organizedPath = "/Volumes/Lexxar/2.m4a"
        r.env.fresh[2] = away
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 1, "a wait, never a skip")
        #expect(nextIDs(r.vm) == [2, 3])
        r.vm.addToQueue([local(9, r)])
        #expect(nextIDs(r.vm) == [9, 2, 3], "editing the queue still works while it waits")
    }

    @Test func aWaitingAdvanceKeepsTheEntryIdentity() async {
        let r = rig()
        let a = local(1, r)
        var away = notDownloaded(2)
        away.organizedPath = "/Volumes/MLMTestsGone-\(UUID().uuidString)/2.m4a"
        await r.vm.playTrack(a, queue: [a, away])
        let before = r.vm.queueSnapshot.upcomingEntries.map(\.id)
        await r.vm.next()
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == before, "the same row stays at the head")
    }

    // MARK: Jumping and History

    @Test func returnOnANextRowPlaysItAndThePassedRowsGoToHistory() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), d = local(4, r), x = local(9, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        r.vm.addToQueue([x])
        // Next = [9 | 2, 3, 4]; jump to 3.
        let three = r.vm.queueSnapshot.contextEntries[1].id
        await r.vm.playQueueEntry(three)
        #expect(r.vm.currentTrack?.id == 3)
        #expect(r.vm.currentEntryID == three, "the row keeps its identity as Now playing")
        #expect(r.vm.history.map(\.id) == [1, 9, 2, 3])
        #expect(nextIDs(r.vm) == [4])
    }

    @Test func aJumpToAPlayNextItemKeepsTheItemsAfterItInTheirLane() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), x = local(8, r), y = local(9, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.vm.addToQueue([x, y])
        let eight = r.vm.queueSnapshot.playNextEntries[0].id
        await r.vm.playQueueEntry(eight)
        #expect(r.vm.queueSnapshot.playNext.map(\.id) == [9], "Play Next items after it stay Play Next items")
        #expect(r.vm.queueSnapshot.context.map(\.id) == [2])
    }

    @Test func replayingFromHistoryKeepsNext() async {
        // PP-MAIN-36: playing something from History used to discard the context.
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), d = local(4, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        await r.vm.next()
        let next = nextIDs(r.vm)
        let firstPlay = r.vm.historyEntries[0].id
        await r.vm.playQueueEntry(firstPlay)
        #expect(r.vm.currentTrack?.id == 1)
        #expect(nextIDs(r.vm) == next, "Next is unchanged")
        #expect(r.vm.history.map(\.id) == [2, 1], "the replayed row moves to the end")
    }

    @Test func aRowThatCantPlayLeavesEverythingAsItWas() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        r.vm.addToQueue([notDownloaded(7)])
        let before = r.vm.queueSnapshot
        await r.vm.playQueueEntry(before.playNextEntries[0].id)
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.queueSnapshot == before)
        #expect(r.vm.notice?.text == "Couldn’t play “T7” — it isn’t downloaded")
    }

    @Test func clearHistoryKeepsTheNowPlayingEntry() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        await r.vm.next()
        let current = r.vm.currentEntryID
        #expect(r.vm.clearHistory() != nil)
        #expect(r.vm.historyEntries.map(\.id) == [current].compactMap { $0 })
    }

    // MARK: Undo through the view model

    @Test func undoAfterTheQueueAdvancedAppliesSensibly() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), d = local(4, r)
        await r.vm.playTrack(a, queue: [a, b, c, d])
        let cEntry = r.vm.queueSnapshot.contextEntries[1].id
        let receipt = r.vm.removeEntries([cEntry])
        #expect(nextIDs(r.vm) == [2, 4])
        await r.vm.next()
        #expect(nextIDs(r.vm) == [4])
        #expect(r.vm.revertQueueEdit(receipt!))
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == [cEntry, r.vm.queueSnapshot.upcomingEntries[1].id])
        #expect(nextIDs(r.vm) == [3, 4])
        #expect(r.vm.reapplyQueueEdit(receipt!))
        #expect(nextIDs(r.vm) == [4])
    }

    @Test func clearStopsAfterThePlayingTrackAndUndoBringsTheQueueBack() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        r.vm.setRepeatMode(.all)
        await r.vm.playTrack(a, queue: [a, b, c])
        let before = r.vm.queueSnapshot
        let receipt = r.vm.clearNext()
        #expect(r.vm.queueSnapshot.isEmpty)
        #expect(r.vm.queueSnapshot.cycle.isEmpty)
        #expect(r.vm.currentTrack?.id == 1, "the playing track continues")
        #expect(r.vm.revertQueueEdit(receipt!))
        #expect(r.vm.queueSnapshot == before)
    }

    // MARK: Rows stay fresh

    @Test func refreshKeepsIdentitiesAndUpdatesTheCopies() async {
        let r = rig()
        let a = local(1, r), b = notDownloaded(2)
        await r.vm.playTrack(a, queue: [a, b])
        let entry = r.vm.queueSnapshot.contextEntries[0]
        var downloaded = b
        downloaded.organizedPath = r.folder.file("2.m4a")
        downloaded.title = "Renamed"
        r.env.fresh = [2: downloaded]
        await r.vm.refreshQueuedTracks()
        let refreshed = r.vm.queueSnapshot.contextEntries[0]
        #expect(refreshed.id == entry.id)
        #expect(refreshed.track.title == "Renamed")
        #expect(refreshed.track.availability() == .local, "the state word goes in place")
    }

    @Test func removedTracksLeaveNextTheCycleAndHistory() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        await r.vm.next()
        r.vm.playNext([a])
        await r.vm.removeTracksFromQueue([1, 3])
        #expect(nextIDs(r.vm).isEmpty)
        #expect(r.vm.queueSnapshot.cycle.map(\.id) == [2])
        #expect(r.vm.history.map(\.id) == [2], "only the playing entry is left")
        #expect(PlaybackViewModel.deletedTrackIDs(["removedIds": [Int64(4), 5]]) == [4, 5])
        #expect(PlaybackViewModel.deletedTrackIDs(["deletedIDs": [Int64(6)]]) == [6])
    }

    // MARK: Preview and queue stay separate (IMP-034)

    @Test func previewsNeverTouchTheQueueOrHistory() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r), p = local(9, r)
        await r.vm.playTrack(a, queue: [a, b, c])
        r.vm.addToQueue([b])
        let queueBefore = r.vm.queueSnapshot
        let historyBefore = r.vm.historyEntries
        let currentBefore = r.vm.currentEntryID
        r.vm.preview.toggle(owner: "queue-panel", candidate: .previewable(p))
        await waitUntil { r.vm.preview.isActive && !r.vm.preview.isLoading }
        #expect(r.vm.preview.isActive)
        r.vm.preview.selectionChanged(owner: "queue-panel", candidate: .previewable(c))
        _ = r.vm.preview.escape()
        #expect(r.vm.queueSnapshot == queueBefore, "same entries, identities, lanes and cycle")
        #expect(r.vm.historyEntries == historyBefore)
        #expect(r.vm.currentEntryID == currentBefore)
    }
}
