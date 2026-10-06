import Foundation

// MARK: - The queue across relaunches (W2-D, UC-TRAIL-05, `queue.html` P-QUEUE.N06)
//
// "Kept when you quit. MLM reopens with this queue, paused." The queue lives in the library's
// own database (`v43_playback_queue`, `PlaybackQueueRepository`), so each library keeps its
// own queue and a library switch (a relaunch) never mixes them.
//
// What is saved: Next (both lanes with entry identities), the Repeat All cycle (identities), History (capped
// by `playback_history_size`), the playing entry and its position, and where the context came
// from (`PlaybackOrigin`, for the `From “‹context›”` link and ⌘L).
// When: after any change of the queue, History, the playing track or the playback state
// (pause, play, stop) — coalesced into one write `saveDelay` later; while playing the position
// is saved at most every `positionInterval`; and synchronously when MLM quits. Writes run off
// the main actor (GRDB's writer), one at a time, and never block transport.

/// The saved queue: identities and track ids only.
struct SavedPlaybackQueue: Equatable, Sendable {
    struct Entry: Equatable, Hashable, Sendable {
        let id: UUID
        let trackID: Int64
    }

    var playNext: [Entry] = []
    var context: [Entry] = []
    /// The Repeat All cycle, in order (entries still queued in the context share their ids).
    var cycle: [Entry] = []
    /// Oldest first; the last one is the playing track's entry while one is loaded.
    var history: [Entry] = []
    /// The playing entry (in `history`) or, when it couldn't be loaded, the waiting one at the
    /// head of Next.
    var currentEntryID: UUID?
    /// Seconds into the playing entry.
    var position: TimeInterval = 0
    /// Where the context was played from.
    var origin: PlaybackOrigin?

    var isEmpty: Bool {
        playNext.isEmpty && context.isEmpty && cycle.isEmpty && history.isEmpty && currentEntryID == nil
    }

    /// Every track id the saved queue refers to.
    var trackIDs: Set<Int64> {
        Set(playNext.map(\.trackID) + context.map(\.trackID) + cycle.map(\.trackID) + history.map(\.trackID))
    }
}

/// Where the saved queue is kept (`PlaybackQueueRepository`; a fake in tests).
protocol PlaybackQueueStoring: Sendable {
    /// Replace the saved queue (one transaction).
    func save(_ queue: SavedPlaybackQueue) async throws
    /// `save`, synchronously (MLM quits).
    func saveNow(_ queue: SavedPlaybackQueue) throws
    /// The saved queue, after removing entries whose track no longer exists; nil = none saved.
    func load() async throws -> SavedPlaybackQueue?
    /// Remove the saved entries of tracks that left the library.
    func removeEntries(trackIDs: Set<Int64>) async throws
}

/// Saves the playback queue, coalesced and off the main actor. Injected scheduler and clock,
/// so tests decide when time passes.
@MainActor
final class PlaybackQueuePersister {
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    /// Changes within this time become one write.
    nonisolated static let saveDelay: Duration = .seconds(1)
    /// While playing, the position is saved at most this often (seconds).
    nonisolated static let positionInterval: TimeInterval = 15

    private let store: any PlaybackQueueStoring
    private let capture: @MainActor () -> SavedPlaybackQueue
    private let schedule: Schedule
    private let now: @MainActor () -> TimeInterval
    private let positionInterval: TimeInterval

    private var isScheduled = false
    private var writing: Task<Void, Never>?
    private var changedWhileWriting = false
    private var lastSaved: SavedPlaybackQueue?
    private var lastPositionMark: TimeInterval?
    /// After the quit flush nothing is written any more.
    private var isFinished = false
    /// Writes that reached the store (tests).
    private(set) var writeCount = 0

    init(
        store: any PlaybackQueueStoring,
        capture: @escaping @MainActor () -> SavedPlaybackQueue,
        schedule: @escaping Schedule = PreviewController.sleepThenRun,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        positionInterval: TimeInterval = PlaybackQueuePersister.positionInterval,
        lastSaved: SavedPlaybackQueue? = nil
    ) {
        self.store = store
        self.capture = capture
        self.schedule = schedule
        self.now = now
        self.positionInterval = positionInterval
        self.lastSaved = lastSaved
    }

    /// The queue, History, the playing track or the playback state changed: save soon (one
    /// write for everything that changes within `saveDelay`).
    func stateDidChange() {
        guard !isFinished, !isScheduled else { return }
        isScheduled = true
        schedule(Self.saveDelay) { [weak self] in self?.fire() }
    }

    /// A tick of the position timer while playing: save the position at most every
    /// `positionInterval`.
    func positionDidTick() {
        let time = now()
        guard let mark = lastPositionMark else {
            lastPositionMark = time
            return
        }
        guard time - mark >= positionInterval else { return }
        lastPositionMark = time
        stateDidChange()
    }

    private func fire() {
        isScheduled = false
        guard !isFinished else { return }
        if writing != nil {
            changedWhileWriting = true
            return
        }
        let snapshot = capture()
        guard snapshot != lastSaved else { return }
        let store = self.store
        writing = Task { @MainActor [weak self] in
            do {
                try await store.save(snapshot)
                self?.lastSaved = snapshot
                self?.writeCount += 1
            } catch {
                AppLogger.shared.log("Playback: couldn’t save the queue: \(error.localizedDescription)",
                                     level: .warning, source: "Playback")
            }
            guard let self else { return }
            self.writing = nil
            if self.changedWhileWriting {
                self.changedWhileWriting = false
                self.stateDidChange()
            }
        }
    }

    /// Save now and stop (MLM quits). Synchronous: the write is queued behind any write in
    /// flight on the same database writer, so it is the last one.
    func flushNow() {
        guard !isFinished else { return }
        isFinished = true
        let snapshot = capture()
        guard snapshot != lastSaved else { return }
        do {
            try store.saveNow(snapshot)
            lastSaved = snapshot
            writeCount += 1
        } catch {
            AppLogger.shared.log("Playback: couldn’t save the queue at quit: \(error.localizedDescription)",
                                 level: .warning, source: "Playback")
        }
    }

    /// Tracks left the library: their saved entries go at once (manual cascade — foreign keys
    /// stay disabled), not only with the next save.
    func removeSavedEntries(trackIDs: Set<Int64>) async {
        guard !trackIDs.isEmpty else { return }
        try? await store.removeEntries(trackIDs: trackIDs)
    }

    /// Waits until no write is running (tests).
    func waitForWrites() async {
        while let writing {
            await writing.value
        }
    }
}

// MARK: - Launch

extension PlaybackQueuePersister {
    /// Restore the library's saved queue into `playback` (paused, never playing), then keep it
    /// saved. Called once per launch when the library opens.
    @discardableResult
    static func restore(
        into playback: PlaybackViewModel,
        store: any PlaybackQueueStoring,
        tracks: @escaping (Set<Int64>) async -> [Int64: Track],
        schedule: @escaping Schedule = PreviewController.sleepThenRun,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async -> PlaybackQueuePersister {
        let saved = (try? await store.load()) ?? nil
        if let saved, !saved.isEmpty {
            let found = await tracks(saved.trackIDs)
            playback.restoreQueue(saved, tracks: found)
        }
        let persister = PlaybackQueuePersister(
            store: store,
            capture: { [weak playback] in playback?.savedQueueState() ?? SavedPlaybackQueue() },
            schedule: schedule,
            now: now,
            lastSaved: saved
        )
        playback.attachQueuePersister(persister)
        // What was dropped on restore (deleted tracks) is written back soon.
        persister.stateDidChange()
        return persister
    }

    /// The app's wiring: the library database and its track rows.
    static func startLive(playback: PlaybackViewModel, store: any PlaybackQueueStoring, trackRepository: TrackRepository) async {
        await restore(into: playback, store: store, tracks: { ids in
            guard !ids.isEmpty, let rows = try? await trackRepository.fetchTracks(ids: ids) else { return [:] }
            var byID: [Int64: Track] = [:]
            for track in rows { if let id = track.id { byID[id] = track } }
            return byID
        })
    }
}

// MARK: - Saving where the context came from

/// `PlaybackOrigin` as JSON (the shell's types stay as they are).
struct SavedPlaybackOrigin: Codable, Equatable {
    enum Container: Codable, Equatable {
        case library
        case playlist(id: Int64, name: String)
        case queue
        case syncProfile(id: Int64, name: String)
        /// The Folders outline (W3-FOLD); older saved origins never contain it.
        case folder(path: String, name: String)
        case genre(key: String, name: String)
        case none
    }

    var place: SidebarDestination
    var path: [DetailRoute]
    var listKey: String
    var container: Container

    init(_ origin: PlaybackOrigin) {
        place = origin.place
        path = origin.path
        listKey = origin.listKey
        switch origin.container {
        case .library: container = .library
        case .playlist(let id, let name): container = .playlist(id: id, name: name)
        case .queue: container = .queue
        case .syncProfile(let id, let name): container = .syncProfile(id: id, name: name)
        case .folder(let path, let name): container = .folder(path: path, name: name)
        case .genre(let key, let name): container = .genre(key: key, name: name)
        // A Review comparison is not a place to come back to.
        case .reviewGroup, .none: container = .none
        }
    }

    var origin: PlaybackOrigin {
        let listContainer: TrackListContainer
        switch container {
        case .library: listContainer = .library
        case .playlist(let id, let name): listContainer = .playlist(id: id, name: name)
        case .queue: listContainer = .queue
        case .syncProfile(let id, let name): listContainer = .syncProfile(id: id, name: name)
        case .folder(let path, let name): listContainer = .folder(path: path, name: name)
        case .genre(let key, let name): listContainer = .genre(key: key, name: name)
        case .none: listContainer = .none
        }
        return PlaybackOrigin(place: place, path: path, listKey: listKey, container: listContainer)
    }

    static func encode(_ origin: PlaybackOrigin?) -> String? {
        guard let origin, let data = try? JSONEncoder().encode(SavedPlaybackOrigin(origin)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ text: String?) -> PlaybackOrigin? {
        guard let text, let data = text.data(using: .utf8),
              let saved = try? JSONDecoder().decode(SavedPlaybackOrigin.self, from: data) else { return nil }
        return saved.origin
    }
}
