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
        r.vm.addToQueue([b])
        #expect(clock.pending.count == 1)
        r.vm.pause()
        clock.fire()
        await saver.waitForWrites()
        #expect(store.saved?.playNext.map(\.trackID) == [2])
        #expect(store.writes == 2)
    }

    // MARK: Restore (W2-D review B1: never touches the audio disk)

    /// A file check that blocks until released (a sleeping or failing disk) and counts calls.
    final class StuckProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var _calls = 0
        private var released = false
        let stuckPath: String

        init(stuckPath: String) { self.stuckPath = stuckPath }

        var calls: Int { lock.withLock { _calls } }

        func fileExists(_ path: String) -> Bool {
            lock.withLock { _calls += 1 }
            if path == stuckPath, !lock.withLock({ released }) { semaphore.wait() }
            return FileManager.default.fileExists(atPath: path)
        }

        func release() {
            lock.withLock { released = true }
            semaphore.signal()
        }
    }

    private func rig(probe: StuckProbe) -> Rig {
        let folder = PlaybackFixtureFolder()
        let env = PlaybackTestEnvironment()
        let main = SilentAudioPlayer()
        var environment = env.environment
        environment.probe = PlaybackFileResolver.Probe(fileExists: { probe.fileExists($0) },
                                                       isVolumeMounted: { _ in true }, isLibraryRootReachable: { _ in true })
        let vm = PlaybackViewModel(audioPlayer: main, environment: environment, previewPlayer: { SilentAudioPlayer() },
                                   previewSchedule: { _, _ in })
        return Rig(vm: vm, main: main, env: env, folder: folder)
    }

    @Test func restoreIsPausedAtThePositionAndKeepsIdentitiesWithoutOpeningTheFile() async {
        let r = rig()
        let a = local(1, r), b = local(2, r), c = local(3, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let context = SavedPlaybackQueue.Entry(id: UUID(), trackID: 2)
        let saved = SavedPlaybackQueue(
            playNext: [.init(id: UUID(), trackID: 3), .init(id: UUID(), trackID: 3)],
            context: [context],
            cycle: [.init(id: UUID(), trackID: 1), context],
            history: [.init(id: UUID(), trackID: 2), current],
            currentEntryID: current.id,
            position: 61,
            origin: PlaybackOrigin(place: .allTracks, path: [], listKey: "allTracks", container: .library)
        )
        let restored = r.vm.restoreQueue(saved, tracks: [1: a, 2: b, 3: c])
        #expect(restored)
        #expect(r.vm.currentTrack?.id == 1, "Now playing shows at once")
        #expect(r.vm.playbackState == .paused)
        #expect(r.vm.currentPosition == 61, "its saved position is shown")
        #expect(r.main.loaded.isEmpty, "the file isn't opened at launch")
        #expect(r.main.state != .playing, "never plays on launch")
        #expect(r.vm.currentEntryID == current.id)
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == (saved.playNext + saved.context).map(\.id))
        #expect(r.vm.queueSnapshot.cycleEntries.map(\.id) == saved.cycle.map(\.id))
        #expect(r.vm.queueSnapshot.cycleEntries.last == r.vm.queueSnapshot.contextEntries.last, "the pass shares the context entry")
        #expect(r.vm.historyEntries.map(\.id) == saved.history.map(\.id))
        #expect(r.vm.playingOrigin == saved.origin)
        #expect(r.vm.savedQueueState() == saved)
        // Play opens it and resumes there.
        r.vm.togglePlayPause()
        await waitUntil { r.main.state == .playing }
        #expect(r.main.loaded.map(\.lastPathComponent) == ["1.m4a"])
        #expect(r.main.seeks == [61])
        #expect(r.vm.currentEntryID == current.id)
        #expect(r.vm.historyEntries.map(\.id) == saved.history.map(\.id), "no second History row")
    }

    @Test func aSlowDiskNeverHoldsTheRestoreAndAUserPlayWins() async {
        let folder = PlaybackFixtureFolder()
        let stuckPath = folder.file("1.m4a")
        let probe = StuckProbe(stuckPath: stuckPath)
        let r = rig(probe: probe)
        defer { probe.release() }
        var a = local(1, r)
        a.organizedPath = stuckPath
        let b = local(2, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let saved = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 2)], history: [current],
                                       currentEntryID: current.id, position: 20)
        // Restore completes without a single file check.
        #expect(r.vm.restoreQueue(saved, tracks: [1: a, 2: b]))
        #expect(probe.calls == 0)
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.vm.queueSnapshot.upcoming.map(\.id) == [2])
        // Play: the open hangs on the disk — off the main actor; the app goes on.
        r.vm.togglePlayPause()
        await waitUntil { probe.calls >= 1 }
        // The user plays something else meanwhile: it wins.
        await r.vm.playTrack(b)
        #expect(r.vm.currentTrack?.id == 2)
        #expect(r.main.state == .playing)
        probe.release()
        await waitUntil { probe.calls >= 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.vm.currentTrack?.id == 2, "the stale open gives up (generation)")
        #expect(r.main.loaded.map(\.lastPathComponent) == ["2.m4a"])
    }

    @Test func seekingAndPreviousOnTheUnopenedTrackUseItsSavedPosition() async {
        let r = rig()
        let a = local(1, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        r.vm.restoreQueue(SavedPlaybackQueue(history: [current], currentEntryID: current.id, position: 50), tracks: [1: a])
        r.vm.seek(to: 80)
        #expect(r.vm.currentPosition == 80)
        #expect(r.vm.savedQueueState().position == 80)
        #expect(r.main.loaded.isEmpty)
        // Previous after more than 3 s restarts it: opens at 0.
        await r.vm.back()
        await waitUntil { r.main.state == .playing }
        #expect(r.main.seeks.isEmpty, "from the start")
        #expect(r.vm.currentTrack?.id == 1)
    }

    @Test func entriesOfTracksThatNoLongerExistAreDropped() async {
        let r = rig()
        let b = local(2, r)
        let kept = SavedPlaybackQueue.Entry(id: UUID(), trackID: 2)
        let saved = SavedPlaybackQueue(
            context: [kept, .init(id: UUID(), trackID: 99)],
            cycle: [.init(id: UUID(), trackID: 99), kept],
            history: [.init(id: UUID(), trackID: 99)],
            currentEntryID: nil
        )
        r.vm.restoreQueue(saved, tracks: [2: b])
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
        r.vm.restoreQueue(saved, tracks: tracks)
        #expect(r.vm.history.map(\.id) == [3, 4])
    }

    @Test func aTrackOnADiskThatIsAwayWaitsAndKeepsEverything() async {
        // IMP-033: restoring while the disk is away keeps the whole queue; the player says why.
        let r = rig()
        let volume = "/Volumes/MLMTestsGone-\(UUID().uuidString)"
        r.env.offlineVolumePath = volume
        var away = local(1, r)
        away.organizedPath = "\(volume)/1.m4a"
        let b = local(2, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let saved = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 2)], history: [current],
                                       currentEntryID: current.id, position: 40)
        r.vm.restoreQueue(saved, tracks: [1: away, 2: b])
        #expect(r.vm.currentTrack == nil)
        if case .driveNotConnected? = r.vm.cantPlay?.reason {} else {
            Issue.record("the player says the disk is not connected, got \(String(describing: r.vm.cantPlay))")
        }
        #expect(r.vm.queueSnapshot.upcomingEntries.map(\.id) == [current.id, saved.context[0].id],
                "the waiting track is at the head of Next, nothing lost")
        #expect(r.vm.historyEntries.isEmpty)
        #expect(r.vm.canResumeQueue)
        #expect(r.vm.savedQueueState().currentEntryID == current.id)
        #expect(r.vm.savedQueueState().position == 40)
        // Something is queued ahead of it: it still keeps its position (review nit).
        r.vm.playNext([b])
        #expect(r.vm.savedQueueState().currentEntryID == current.id)
        #expect(r.vm.savedQueueState().position == 40)
    }

    @Test func aWaitingRestoredTrackStartsAtItsPositionWhenItCanPlay() async {
        let r = rig()
        var a = local(1, r)
        a.fileMissingSince = "2026-10-05T10:00:00Z"
        let b = local(2, r)
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: 1)
        let saved = SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 2)], history: [current],
                                       currentEntryID: current.id, position: 33)
        r.vm.restoreQueue(saved, tracks: [1: a, 2: b])
        #expect(r.vm.cantPlay?.reason == .fileMissing)
        // The file is back (Locate File…): Play continues the queue from it, at its position.
        var found = a
        found.fileMissingSince = nil
        r.env.fresh[1] = found
        await r.vm.next()
        #expect(r.vm.currentTrack?.id == 1)
        #expect(r.main.seeks.last == 33)
        #expect(r.vm.currentEntryID == current.id, "it keeps its entry")
        #expect(r.vm.cantPlay == nil)
    }

    @Test func restoreNeverReplacesWhatAlreadyPlays() async {
        let r = rig()
        let a = local(1, r)
        await r.vm.playTrack(a)
        let restored = r.vm.restoreQueue(SavedPlaybackQueue(context: [.init(id: UUID(), trackID: 1)]), tracks: [1: a])
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
        r.vm.playNext([inserted[2]])
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
