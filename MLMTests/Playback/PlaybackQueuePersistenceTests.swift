import Foundation
import GRDB
import Testing
@testable import MLM

/// W2-D: the queue across relaunches — coalesced writes (injected scheduler and clock),
/// restore paused and defensive, round trip through the real repository.
@Suite("PlaybackQueuePersistenceTests")
@MainActor
struct PlaybackQueuePersistenceTests {
    /// A store in memory; `gate` holds writes while closed.
    final class MemoryStore: PlaybackQueueStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var _saved: SavedPlaybackQueue?
        private var _writes = 0
        private var _removed: [Set<Int64>] = []
        let gate: TestGate

        init(saved: SavedPlaybackQueue? = nil, gate: TestGate) {
            _saved = saved
            self.gate = gate
        }

        var saved: SavedPlaybackQueue? { lock.withLock { _saved } }
        var writes: Int { lock.withLock { _writes } }
        var removed: [Set<Int64>] { lock.withLock { _removed } }

        func save(_ queue: SavedPlaybackQueue) async throws {
            await gate.pass()
            lock.withLock {
                _saved = queue
                _writes += 1
            }
        }

        func saveNow(_ queue: SavedPlaybackQueue) throws {
            lock.withLock {
                _saved = queue
                _writes += 1
            }
        }

        func load() async throws -> SavedPlaybackQueue? { saved }

        func removeEntries(trackIDs: Set<Int64>) async throws {
            lock.withLock { _removed.append(trackIDs) }
        }
    }

    /// Scheduled work and a clock the test moves.
    @MainActor
    final class Clock {
        var now: TimeInterval = 1_000
        var pending: [(Duration, @MainActor () -> Void)] = []

        func fire() {
            let all = pending
            pending = []
            all.forEach { $0.1() }
        }
    }

    struct Rig {
        let vm: PlaybackViewModel
        let main: SilentAudioPlayer
        let env: PlaybackTestEnvironment
        let folder: PlaybackFixtureFolder
    }

    private func rig() -> Rig {
        let folder = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment()
        let main = SilentAudioPlayer()
        let vm = PlaybackViewModel(audioPlayer: main, environment: env.environment, previewPlayer: { SilentAudioPlayer() },
                                   previewSchedule: { _, _ in })
        return Rig(vm: vm, main: main, env: env, folder: folder)
    }

    private func local(_ id: Int64, _ rig: Rig) -> Track {
        var t = Track(artist: "Artist", album: "Album", title: "T\(id)", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = rig.folder.file("\(id).m4a")
        t.duration = 200
        return t
    }

    private func persister(_ store: MemoryStore, clock: Clock, capture: @escaping @MainActor () -> SavedPlaybackQueue) -> PlaybackQueuePersister {
        PlaybackQueuePersister(store: store, capture: capture,
                               schedule: { delay, work in clock.pending.append((delay, work)) },
                               now: { clock.now })
    }

    // MARK: Coalesced writes

    @Test func changesBecomeOneWriteAfterTheDelay() async {
        let clock = Clock()
        let store = MemoryStore(gate: TestGate())
        var state = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 1)])
        let saver = persister(store, clock: clock) { state }
        saver.stateDidChange()
        saver.stateDidChange()
        state.position = 4
        saver.stateDidChange()
        #expect(clock.pending.count == 1, "one write scheduled for many changes")
        #expect(clock.pending.first?.0 == PlaybackQueuePersister.saveDelay)
        #expect(store.writes == 0, "nothing written before the delay")
        clock.fire()
        await saver.waitForWrites()
        #expect(store.writes == 1)
        #expect(store.saved == state, "the state at write time")
        // Nothing changed since: no second write.
        saver.stateDidChange()
        clock.fire()
        await saver.waitForWrites()
        #expect(store.writes == 1)
    }

    @Test func aChangeDuringAWriteIsWrittenAfterIt() async {
        let clock = Clock()
        let gate = TestGate()
        let store = MemoryStore(gate: gate)
        var state = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 1)])
        let saver = persister(store, clock: clock) { state }
        gate.close()
        saver.stateDidChange()
        clock.fire()
        await waitUntil { gate.waiting == 1 }
        state.context.append(.init(id: UUID(), trackID: 2))
        saver.stateDidChange()
        clock.fire()  // fires while the first write is held: noted, not a second parallel write
        #expect(gate.waiting == 1)
        gate.open()
        await saver.waitForWrites()
        // The write that was asked for meanwhile is scheduled again.
        await waitUntil { !clock.pending.isEmpty }
        clock.fire()
        await saver.waitForWrites()
        #expect(store.writes == 2)
        #expect(store.saved == state)
    }

    @Test func thePositionIsSavedAtMostEveryInterval() async {
        let clock = Clock()
        let store = MemoryStore(gate: TestGate())
        var state = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 1)])
        let saver = persister(store, clock: clock) { state }
        saver.positionDidTick()  // the first tick only starts the interval
        #expect(clock.pending.isEmpty)
        clock.now += PlaybackQueuePersister.positionInterval - 1
        state.position = 14
        saver.positionDidTick()
        #expect(clock.pending.isEmpty, "not yet")
        clock.now += 1
        saver.positionDidTick()
        #expect(clock.pending.count == 1)
        clock.fire()
        await saver.waitForWrites()
        #expect(store.saved?.position == 14)
    }

    @Test func quitWritesSynchronouslyAndStopsSaving() async {
        let clock = Clock()
        let store = MemoryStore(gate: TestGate())
        var state = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 1)])
        let saver = persister(store, clock: clock) { state }
        saver.stateDidChange()
        saver.flushNow()
        #expect(store.writes == 1)
        #expect(store.saved == state)
        state.position = 9
        clock.fire()
        saver.stateDidChange()
        #expect(clock.pending.isEmpty, "nothing after the quit flush")
        await saver.waitForWrites()
        #expect(store.writes == 1)
    }

    @Test func theViewModelAsksForASaveOnEveryQueueChange() async {
        let r = rig()
        let clock = Clock()
        let store = MemoryStore(gate: TestGate())
        let saver = persister(store, clock: clock) { [vm = r.vm] in vm.savedQueueState() }
        r.vm.attachQueuePersister(saver)
        let a = local(1, r), b = local(2, r)
        await r.vm.playTrack(a, queue: [a, b])
        #expect(clock.pending.count == 1)
        clock.fire()
        await saver.waitForWrites()
        #expect(store.saved?.context.map(\.trackID) == [2])
        #expect(store.saved?.currentEntryID == r.vm.currentEntryID)
        await r.vm.addToQueue([b])
        #expect(clock.pending.count == 1)
        r.vm.pause()
        clock.fire()
        await saver.waitForWrites()
        #expect(store.saved?.playNext.map(\.trackID) == [2])
        #expect(store.writes == 2)
    }

    // MARK: Restore

    @Test func restoreIsPausedAtThePositionAndKeepsIdentities() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let saved = SavedPlaybackQueue(
            playNext: [.init(id: UUID(), trackID: 3), .init(id: UUID(), trackID: 3)],
            context: [.init(id: UUID(), trackID: 2)],
            cycle: [1, 2],
            history: [.init(id: UUID(), trackID: 2), current],
            currentEntryID: current.id,
            position: 61,
            origin: PlaybackOrigin(place: .allTracks, path: [], listKey: "allTracks", container: .library)
        )
        let restored = await r.vm.restoreQueue(saved, tracks: [1: a, 2: b, 3: c])
        #expect(restored)
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.playbackState == .paused)
        #expect(r.main.state != .playing, "never plays on launch")
        #expect(r.main.seeks == [61])
        #expect(r.vm.currentEntryID == current.id)
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == (saved.playNext + saved.context).map(\.id))
        #expect(r.vm.queueSnapshot.cycle.map(\.id) == [1, 2])
        #expect(r.vm.historyEntries.map(\.id) == saved.history.map(\.id))
        #expect(r.vm.playingOrigin == saved.origin)
        #expect(r.vm.savedQueueState() == SavedPlaybackQueue(
            playNext: saved.playNext, context: saved.context, cycle: saved.cycle, history: saved.history,
            currentEntryID: current.id, position: 61, origin: saved.origin))
        // Play resumes there.
        r.vm.togglePlayPause()
        #expect(r.main.state == .playing)
    }

    @Test func entriesOfTracksThatNoLongerExistAreDropped() async {
        let r = rig()
        let b = local(2, r)
        let saved = SavedPlaybackQueue(
            context: [.init(id: UUID(), trackID: 2), .init(id: UUID(), trackID: 99)],
            cycle: [99, 2],
            history: [.init(id: UUID(), trackID: 99)],
            currentEntryID: nil
        )
        await r.vm.restoreQueue(saved, tracks: [2: b])
        #expect(r.vm.queueSnapshot.upcoming.map(\.id) == [2])
        #expect(r.vm.queueSnapshot.cycle.map(\.id) == [2])
        #expect(r.vm.historyEntries.isEmpty)
        #expect(r.vm.currentTrack == nil)
    }

    @Test func historyIsCappedOnRestore() async {
        let r = rig()
        r.env.defaults.set(2, forKey: "playback_history_size")
        let tracks = Dictionary(uniqueKeysWithValues: (1...4).map { (Int64($0), local(Int64($0), r)) })
        let saved = SavedPlaybackQueue(history: (1...4).map { .init(id: UUID(), trackID: Int64($0)) })
        await r.vm.restoreQueue(saved, tracks: tracks)
        #expect(r.vm.history.map(\.id) == [3, 4])
    }

    @Test func aTrackOnADiskThatIsAwayWaitsAndKeepsEverything() async {
        // IMP-033: restoring while the disk is away keeps the whole queue; the player says why.
        let r = rig()
        var away = local(1, r)
        away.organizedPath = "/Volumes/MLMTestsGone-\(UUID().uuidString)/1.m4a"
        let b = local(2, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let saved = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 2)], history: [current],
                                       currentEntryID: current.id, position: 40)
        await r.vm.restoreQueue(saved, tracks: [1: away, 2: b])
        #expect(r.vm.currentTrack == nil)
        if case .driveNotConnected? = r.vm.cantPlay?.reason {} else {
            Issue.record("the player says the disk is not connected, got \(String(describing: r.vm.cantPlay))")
        }
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == [current.id, saved.context[0].id],
                "the waiting track is at the head of Next, nothing lost")
        #expect(r.vm.historyEntries.isEmpty)
        #expect(r.vm.canResumeQueue)
        // Saved again as it is: the waiting entry with its position.
        #expect(r.vm.savedQueueState().currentEntryID == current.id)
        #expect(r.vm.savedQueueState().position == 40)
    }

    @Test func aWaitingRestoredTrackStartsAtItsPositionWhenItCanPlay() async {
        let r = rig()
        let a = local(1, r), b = local(2, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let saved = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 2)], history: [current],
                                       currentEntryID: current.id, position: 33)
        r.folder.remove("1.m4a")
        await r.vm.restoreQueue(saved, tracks: [1: a, 2: b])
        #expect(r.vm.cantPlay?.reason == .fileMissing)
        // The file is back (Locate File…), Play continues the queue from it, at its position.
        r.folder.file("1.m4a")
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.main.seeks.last == 33)
        #expect(r.vm.cantPlay == nil)
    }

    @Test func restoreNeverReplacesWhatAlreadyPlays() async {
        let r = rig()
        let a = local(1, r)
        await r.vm.playTrack(a)
        let restored = await r.vm.restoreQueue(SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 1)]), tracks: [1: a])
        #expect(!restored)
        #expect(r.vm.queueSnapshot.isEmpty)
    }

    // MARK: Round trip through the database

    @Test func aQueueSavedByOneLaunchComesBackInTheNext() async throws {
        let db = try DatabaseManager.inMemory()
        let repository = PlaybackQueueRepository(database: db)
        let trackRepository = TrackRepository(database: db)
        let r = rig()
        var inserted: [Track] = []
        for id in 1...3 {
            var track = local(Int64(id), r)
            track.id = nil
            inserted.append(try await trackRepository.insert(track))
        }
        let ids = inserted.compactMap(\.id)
        let clock = Clock()
        let first = await PlaybackQueuePersister.restore(
            into: r.vm, store: repository,
            tracks: { _ in [:] },
            schedule: { delay, work in clock.pending.append((delay, work)) },
            now: { clock.now })
        await r.vm.playTrack(inserted[0], queue: inserted)
        await r.vm.playNext([inserted[2]])
        r.main.currentPosition = 12
        r.vm.pause()
        clock.fire()
        await first.waitForWrites()
        let expected = r.vm.savedQueueState()

        // Next launch.
        let second = rig()
        let lookup: (Set<Int64>) async -> [Int64: Track] = { wanted in
            var byID: [Int64: Track] = [:]
            for track in (try? await trackRepository.fetchTracks(ids: wanted)) ?? [] { byID[track.id!] = track }
            return byID
        }
        _ = await PlaybackQueuePersister.restore(into: second.vm, store: repository, tracks: lookup,
                                                 schedule: { _, _ in }, now: { 0 })
        #expect(second.vm.currentTrack?.id == ids[0])
        #expect(second.vm.playbackState == .paused)
        #expect(second.main.state != .playing)
        #expect(second.vm.queueSnapshot.upcoming.map(\.id) == [ids[2], ids[1], ids[2]])
        #expect(second.vm.savedQueueState() == expected)
    }
}
