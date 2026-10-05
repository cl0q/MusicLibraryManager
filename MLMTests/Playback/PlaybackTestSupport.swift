import Foundation
@testable import MLM

// MARK: - Fakes shared by the W2-C view-model tests

/// An audio player that plays nothing (no sound reaches the output device). Like
/// `AudioPlayer`, a file that can't be opened leaves the loaded one untouched.
@MainActor
final class SilentAudioPlayer: AudioPlayerControlling {
    var state: AudioPlayer.PlaybackState = .stopped
    var duration: TimeInterval = 200
    var currentPosition: TimeInterval = 0
    private(set) var loaded: [URL] = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var volumes: [Float] = []
    var failLoad = false
    /// Paths that can't be opened (decode failure).
    var unreadable: Set<String> = []

    func loadFile(at url: URL) throws {
        if failLoad || unreadable.contains(url.path) { throw NSError(domain: "Silent", code: -1) }
        state = .stopped
        currentPosition = 0
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
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        return path
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A switch a test opens to let a suspended call continue (no clocks).
@MainActor
final class TestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isClosed = false
    /// How many calls are waiting now.
    var waiting: Int { waiters.count }

    func close() { isClosed = true }

    func pass() async {
        guard isClosed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isClosed = false
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

/// An injected environment: a throwaway `UserDefaults` suite, no `DependencyContainer`, file
/// checks on the temporary folder (S11).
@MainActor
final class PlaybackTestEnvironment {
    var libraryRoot: String?
    var offlineVolumePath: String?
    var volumeName: String? = "Lexxar"
    var recordedMissing: [Int64] = []
    var checkedFiles: [Set<Int64>] = []
    var fresh: [Int64: Track] = [:]
    var drops: [Int64: Double] = [:]
    /// Closed: `freshTracks` (the first await of a queue advance) waits until it opens.
    let freshGate = TestGate()
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
            probe: PlaybackFileResolver.Probe(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                // No real `/Volumes/…` in tests: a volume counts as mounted when its folder exists.
                isVolumeMounted: { FileManager.default.fileExists(atPath: $0) },
                isLibraryRootReachable: { FileManager.default.fileExists(atPath: $0) }
            ),
            recordMissing: { [unowned self] id in self.recordedMissing.append(id) },
            checkFiles: { [unowned self] ids in self.checkedFiles.append(ids) },
            freshTracks: { [unowned self] ids in
                await self.freshGate.pass()
                return self.fresh.filter { ids.contains($0.key) }
            },
            dropOffset: { [unowned self] id in self.drops[id] },
            defaults: defaults,
            observesNotifications: false
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
