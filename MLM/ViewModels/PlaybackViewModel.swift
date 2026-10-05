import Foundation
import SwiftUI
import AVFoundation

// MARK: - What playback needs from the rest of the app

/// Everything playback reads or reports outside the audio engine, as closures so tests run
/// without a library, a disk or `UserDefaults.standard`. `live` reads `DependencyContainer`.
/// Tests always pass their own environment (W2-C review S11).
struct PlaybackEnvironment {
    /// The library folder (`library_root`).
    var libraryRoot: @MainActor () async -> String?
    /// The library disk's `/Volumes/‹name›` while it is not connected; `nil` = connected.
    var offlineVolumePath: @MainActor () -> String?
    /// The library disk's name (`Lexxar`), for sentences.
    var volumeName: @MainActor () -> String?
    /// Use-time file checks (only when a track is about to play; run off the main actor).
    var probe: PlaybackFileResolver.Probe
    /// Playback met a missing file while its folder was reachable (W2-A contract:
    /// `LibraryAvailabilityMonitor.recordMissingAtUse`).
    var recordMissing: @MainActor (Int64) async -> Void
    /// Several files went missing in a row: let the file check judge them (`.tracks(ids)` —
    /// it has the suspicious-abort guard) instead of flagging them here.
    var checkFiles: @MainActor (Set<Int64>) -> Void
    /// The persisted rows of these tracks now (queued copies may be stale: a download may have
    /// finished since they were queued). Missing ids keep their queued copy.
    var freshTracks: @MainActor (Set<Int64>) async -> [Int64: Track]
    /// The analysed drop for the preview hot spot.
    var dropOffset: @MainActor (Int64) async -> Double?
    /// Volume, Repeat, history size and context cap live here (app-wide).
    var defaults: UserDefaults

    static func live(configRepository: ConfigRepository?) -> PlaybackEnvironment {
        PlaybackEnvironment(
            libraryRoot: { (try? await configRepository?.getLibraryRoot()) ?? nil },
            offlineVolumePath: {
                let container = DependencyContainer.shared
                return LibraryDriveState.current(container).isOffline ? container.mountObserver?.libraryVolumePath : nil
            },
            volumeName: { LibraryDriveState.current(.shared).volumeName },
            probe: .live,
            recordMissing: { id in await DependencyContainer.shared.availabilityMonitor?.recordMissingAtUse(trackID: id) },
            checkFiles: { ids in DependencyContainer.shared.availabilityMonitor?.request(.tracks(ids)) },
            freshTracks: { ids in
                guard !ids.isEmpty, let repository = DependencyContainer.shared.trackRepository,
                      let tracks = try? await repository.fetchTracks(ids: ids) else { return [:] }
                var byID: [Int64: Track] = [:]
                for track in tracks { if let id = track.id { byID[id] = track } }
                return byID
            },
            dropOffset: { id in (try? await TrackLocateRepository.live()?.dropOffset(trackID: id)) ?? nil },
            defaults: .standard
        )
    }
}

/// A status-bar note from playback (skips, refusals, failures). The window shows it in its
/// status bar (`PlaybackWindowSupport`); the view model never builds UI.
struct PlaybackNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let action: Action?

    enum Action: Equatable {
        case download([Track])
        case locate(Track)
        case showInFinder(URL)
        case tryAgain(Track)
    }

    static func == (lhs: PlaybackNotice, rhs: PlaybackNotice) -> Bool { lhs.id == rhs.id }
}

/// The track the player names while nothing can play, and why (§15.7).
struct CantPlayState: Equatable {
    let track: Track
    let reason: PlaybackWords.CantPlay
}

/// Where the playing track was started from — Go to Current Track ⌘L returns there.
struct PlaybackOrigin: Equatable {
    var place: SidebarDestination
    var path: [DetailRoute]
    /// The table's `TrackListConfiguration.persistenceKey` and container.
    var listKey: String
    var container: TrackListContainer
}

/// What Now Playing (Control Center, media keys, the Dock menu) shows: the preview while one
/// runs, else the main track.
struct NowPlayingSnapshot: Equatable {
    let trackID: Int64?
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
}

extension Notification.Name {
    /// The preview started, moved, paused or ended (Now Playing follows it).
    static let playbackPreviewDidChange = Notification.Name("MLMPlaybackPreviewDidChange")
}

/// Playback: the main player, the queue and history, and the transient Space preview.
///
/// - The queue's next track comes from `QueueAdvance` (pure, tested). A track that can't play
///   for a reason of its own is passed over (it moves to History with its state word) with
///   one status-bar note per run; a track whose disk is away is a **wait**: nothing is taken
///   out of the queue (DEC-014, DEC-045, PP-MAIN-01).
/// - Every user transport action and every preview start takes a new playback *generation*;
///   a queue advance that awaited something re-checks it and gives up when the user acted
///   meanwhile. Advances, Previous and queue jumps run one after another.
/// - Failures are words (`PlaybackWords`, §15.7); raw error text only goes to the log
///   (PP-MAIN-15). An unplugged disk is never reported as a file problem (DEC-014).
/// - The preview (`preview`) uses a second, transient player; the main track pauses and
///   resumes where it was; the queue and history never change for a preview.
///
/// Designed as a singleton injected via `DependencyContainer`.
@Observable
final class PlaybackViewModel {

    // MARK: - Main playback state

    /// The loaded main track (nil when nothing is loaded).
    private(set) var currentTrack: Track?

    /// State of the main player.
    private(set) var playbackState: AudioPlayer.PlaybackState = .stopped

    /// Main position in seconds.
    private(set) var currentPosition: TimeInterval = 0

    /// Main duration in seconds.
    private(set) var duration: TimeInterval = 0

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentPosition / duration
    }

    var formattedPosition: String { formatTime(currentPosition) }
    var formattedDuration: String { formatTime(duration) }

    /// Something is audible now: the preview while one runs, else the main track. The
    /// Play/Pause button, the Playback and Dock menus and the media keys act on it.
    @MainActor
    var isPlaying: Bool {
        if let preview = previewController, preview.isActive {
            return !preview.isLoading && !preview.isPaused
        }
        return playbackState == .playing
    }

    /// The main track itself is playing (the tables' now-playing glyph).
    var isMainPlaying: Bool { playbackState == .playing }

    /// A main track is loaded (playing or paused).
    var hasTrack: Bool { currentTrack != nil }

    /// Nothing is loaded but the queue has tracks: Play continues it (e.g. after the disk that
    /// held the next track came back).
    var canResumeQueue: Bool { currentTrack == nil && !queueSnapshot.upcoming.isEmpty }

    /// Nothing can play and the player says why (§15.7). Cleared by the next playback, by Stop,
    /// and re-judged when the disk returns or a track's availability changes (S10).
    private(set) var cantPlay: CantPlayState?

    /// The newest status-bar note (shown once by the window).
    private(set) var notice: PlaybackNotice?

    /// Waveform peaks of the main track (0…1 per bin).
    private(set) var waveformData: [Float] = []
    private(set) var isLoadingWaveform = false
    @ObservationIgnored private var waveformTask: Task<Void, Never>?

    /// Volume of both players (0…1), remembered between launches (UC-TB-06).
    private(set) var volume: Double = 1.0
    static let volumeDefaultsKey = "playback_volume"

    /// Playback ▸ Repeat, remembered between launches.
    private(set) var repeatMode: PlaybackRepeatMode = .off

    /// Where the main track was started from (⌘L).
    private(set) var playingOrigin: PlaybackOrigin?

    // MARK: - Preview state (read by the player)

    private(set) var previewPosition: TimeInterval = 0
    private(set) var previewDuration: TimeInterval = 0
    private(set) var previewWaveform: [Float] = []
    @ObservationIgnored private var previewWaveformTask: Task<Void, Never>?

    // MARK: - Queue

    @ObservationIgnored private var queue = PlaybackQueue()

    /// The tracks the queue passed, most recent last: the ones that played and the ones it
    /// passed over because they couldn't play (they keep their state word). Repeat One adds no
    /// entries. Capped by `playback_history_size`.
    private(set) var history: [Track] = []

    /// Upcoming tracks: Play Next items first, then the context.
    var upcoming: [Track] { queueSnapshot.upcoming }

    /// The queue as an observable value (W2-D's Queue panel reads it).
    private(set) var queueSnapshot = PlaybackQueue()

    // MARK: - Dependencies

    @ObservationIgnored private let audioPlayer: any AudioPlayerControlling
    @ObservationIgnored private let makePreviewPlayer: () -> any AudioPlayerControlling
    @ObservationIgnored private var previewPlayer: (any AudioPlayerControlling)?
    @ObservationIgnored private let configRepository: ConfigRepository?
    @ObservationIgnored private let environment: PlaybackEnvironment
    @ObservationIgnored private let previewSchedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private var positionTimer: Timer?
    @ObservationIgnored private let waveformCacheDirectory: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The file the main player has open.
    @ObservationIgnored private(set) var currentURL: URL?
    /// The preview player is running (detects its natural end).
    @ObservationIgnored private var previewAudioRunning = false
    @ObservationIgnored private var previewController: PreviewController?
    @ObservationIgnored private var previewAdapter: PreviewAudioAdapter?
    /// Set by a list right before it activates a row (⌘L returns to it); `trackID == nil`
    /// matches the next playback whatever track it starts with (Shuffle).
    @ObservationIgnored private var pendingOrigin: (trackID: Int64?, origin: PlaybackOrigin)?
    /// Return during a preview: the next `playTrack` of this track starts here.
    @ObservationIgnored private var pendingStart: (trackID: Int64, position: TimeInterval)?
    /// The file macOS couldn't decode last (`Show in Finder` in its note).
    @ObservationIgnored private var lastUnreadableURL: URL?
    /// Advances, Previous and queue jumps run one after another.
    @ObservationIgnored private var transportChain: Task<Void, Never>?
    /// Taken by every user transport action and preview start (S1).
    @ObservationIgnored private(set) var generation = 0
    /// The main track ended and its advance hasn't run yet (a preview may defer it).
    @ObservationIgnored private var endedAwaitingAdvance = false
    /// The advance of an ended main track waits for the preview to end.
    @ObservationIgnored private var advanceAfterPreview = false
    /// Releases the preview player's engine a while after the last preview (S3).
    @ObservationIgnored private var previewReleaseToken = 0

    // MARK: - Init

    init(
        audioPlayer: any AudioPlayerControlling = AudioPlayer(),
        configRepository: ConfigRepository? = nil,
        waveformCacheDirectory: URL = ActiveLibrary.defaultWaveformCacheRoot,
        environment: PlaybackEnvironment? = nil,
        previewPlayer: @escaping () -> any AudioPlayerControlling = { AudioPlayer() },
        previewSchedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = PreviewController.sleepThenRun
    ) {
        self.audioPlayer = audioPlayer
        self.configRepository = configRepository
        self.waveformCacheDirectory = waveformCacheDirectory
        self.environment = environment ?? .live(configRepository: configRepository)
        self.makePreviewPlayer = previewPlayer
        self.previewSchedule = previewSchedule

        let defaults = self.environment.defaults
        if let stored = defaults.object(forKey: Self.volumeDefaultsKey) as? Double {
            volume = min(max(stored, 0), 1)
        }
        audioPlayer.setVolume(Float(volume))
        if let raw = defaults.string(forKey: PlaybackRepeatMode.defaultsKey), let mode = PlaybackRepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        // `Can’t play — …` is judged again when the disk returns or availability changes (S10).
        // (The disk going away is decided by the window's drive handling, `endPreviewForDiskLoss`.)
        for name in [Notification.Name.libraryDriveDidMount, .trackAvailabilityDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let diskReturned = note.name == .libraryDriveDidMount
                MainActor.assumeIsolated { self?.reevaluateCantPlay(diskReturned: diskReturned) }
            })
        }
    }

    deinit {
        positionTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// A user transport action or a preview start: in-flight advances give up (S1).
    @MainActor
    @discardableResult
    private func takeGeneration() -> Int {
        generation += 1
        endedAwaitingAdvance = false
        return generation
    }

    // MARK: - Playing a track (explicit)

    /// Play `track` alone (its context is empty; Play Next items stay).
    @MainActor
    func playTrack(_ track: Track) async {
        await playTrack(track, queue: [track])
    }

    /// Play `track`; the rows after it in `rows` become the queue context (UC-KEY-02).
    ///
    /// The track was chosen by the user, so it is opened as asked (also a track without an
    /// organized path whose original file exists). When it can't play, the current playback
    /// (and a running preview) is left as it was and the player or the status bar says why.
    @MainActor
    func playTrack(_ track: Track, queue rows: [Track]) async {
        let generation = takeGeneration()
        let start = consumePendingStart(for: track)
        let origin = consumePendingOrigin(for: track)
        let proposed = QueueAdvance.start(track, in: rows, queue: queue, cap: contextCap())
        switch await open(track, startAt: start, generation: generation, recordMissing: true) {
        case .playing:
            setQueue(proposed)
            playingOrigin = origin
        case .superseded:
            break
        case .unavailable(let reason):
            previewController?.end()
            reportUnplayable(track, reason)
        case .outputFailed:
            previewController?.end()
            notify(PlaybackWords.outputFailed(track.title), action: .tryAgain(track))
        }
    }

    /// Play the tracks in random order. Playable ones come first, so the first track plays.
    @MainActor
    func playShuffled(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        let offline = environment.offlineVolumePath()
        let shuffled = tracks.shuffled()
        let ordered = shuffled.filter { PlaybackPlayability.of($0, offlineVolumePath: offline).isPlayable }
            + shuffled.filter { !PlaybackPlayability.of($0, offlineVolumePath: offline).isPlayable }
        await playTrack(ordered[0], queue: ordered)
    }

    /// Load a file URL and start playback (Reels and other non-library previews).
    @MainActor
    @discardableResult
    func playFile(at url: URL, track: Track? = nil) async -> Bool {
        takeGeneration()
        switch loadAndStart(url: url, track: track, startAt: nil, recordHistory: true) {
        case .playing:
            return true
        case .superseded:
            return false
        case .unavailable(let reason):
            previewController?.end()
            if let track { reportUnplayable(track, reason) }
            return false
        case .outputFailed:
            previewController?.end()
            if let track { notify(PlaybackWords.outputFailed(track.title), action: .tryAgain(track)) }
            return false
        }
    }

    /// The result of trying to open a track.
    enum OpenResult: Equatable {
        case playing
        /// The user did something else meanwhile; nothing was changed.
        case superseded
        case unavailable(PlaybackPlayability)
        /// The audio output didn't start — not the track's fault.
        case outputFailed
    }

    /// Find the file (a use-time check, off the main actor), then load and play it — unless the
    /// user acted meanwhile (`generation`). A missing file is recorded only when
    /// `recordMissing` (a queue advance decides itself, see the circuit breaker).
    @MainActor
    private func open(_ track: Track, startAt: TimeInterval?, generation: Int, recordMissing: Bool,
                      recordHistory: Bool = true) async -> OpenResult {
        let root = await environment.libraryRoot()
        let lookup = await PlaybackFileResolver.lookupOffMain(track, libraryRoot: root, probe: environment.probe)
        guard generation == self.generation else { return .superseded }
        switch lookup {
        case .file(let url):
            return loadAndStart(url: url, track: track, startAt: startAt, recordHistory: recordHistory)
        case .missing:
            AppLogger.shared.log("Playback: file missing for track id=\(track.id ?? -1) organized='\(track.organizedPath ?? "")'",
                                 level: .warning, source: "Playback")
            if recordMissing, let id = track.id { await environment.recordMissing(id) }
            return .unavailable(.fileMissing)
        case .driveNotConnected:
            return .unavailable(.driveNotConnected)
        case .noFile:
            return .unavailable(.notDownloaded)
        }
    }

    /// Load and play. A file that can't be opened leaves the playing one alone (S8); a running
    /// preview stops only once the new file opened (never two audible sources).
    @MainActor
    private func loadAndStart(url: URL, track: Track?, startAt: TimeInterval?, recordHistory: Bool) -> OpenResult {
        do {
            try audioPlayer.loadFile(at: url)
        } catch {
            AppLogger.shared.log("Playback: can’t open \(url.lastPathComponent): \(error.localizedDescription)",
                                 level: .warning, source: "Playback")
            lastUnreadableURL = url
            return .unavailable(.unreadable)
        }
        previewController?.abandon()
        audioPlayer.applyLUFSCompensation(lufsI: track?.lufsI)
        if let startAt, startAt > 0, startAt < audioPlayer.duration {
            try? audioPlayer.seek(to: startAt)
        }
        do {
            try audioPlayer.play()
        } catch {
            AppLogger.shared.log("Playback: audio output didn’t start: \(error.localizedDescription)",
                                 level: .error, source: "Playback")
            audioPlayer.stop()
            clearStoppedPlaybackState()
            postStateDidChange()
            return .outputFailed
        }
        currentTrack = track
        currentURL = url
        cantPlay = nil
        endedAwaitingAdvance = false
        duration = audioPlayer.duration
        currentPosition = audioPlayer.currentPosition
        playbackState = .playing
        if recordHistory, let track { appendHistory([track]) }
        postTrackDidChange()
        postStateDidChange()
        startPositionTimer()
        extractWaveform(for: url, trackID: track?.id)
        return .playing
    }

    /// A track the user asked for can't play: with nothing loaded the player says it (§15.7);
    /// while something plays, that keeps playing and the status bar says it.
    @MainActor
    private func reportUnplayable(_ track: Track, _ reason: PlaybackPlayability) {
        guard let words = PlaybackWords.CantPlay(reason, volumeName: volumeName(for: track)) else { return }
        if currentTrack == nil {
            cantPlay = CantPlayState(track: track, reason: words)
        }
        let url = reason == .unreadable ? lastUnreadableURL : nil
        notify(PlaybackWords.couldntPlay(track.title, words), action: Self.fix(for: words, track: track, url: url))
    }

    private static func fix(for reason: PlaybackWords.CantPlay, track: Track, url: URL?) -> PlaybackNotice.Action? {
        switch reason {
        case .notDownloaded: .download([track])
        case .fileMissing: .locate(track)
        case .driveNotConnected: nil
        case .unreadable: url.map { .showInFinder($0) }
        }
    }

    @MainActor
    private func notify(_ text: String, action: PlaybackNotice.Action?) {
        notice = PlaybackNotice(text: text, action: action)
    }

    /// The name of the disk a track's file lives on (`Lexxar`), for sentences.
    @MainActor
    private func volumeName(for track: Track) -> String? {
        if let organized = track.organizedPath, (organized as NSString).isAbsolutePath,
           let volume = MountObserver.extractVolumePath(from: organized) {
            return LibraryDriveState.volumeName(fromVolumePath: volume)
        }
        return environment.volumeName()
    }

    /// Add to history (capped).
    private func appendHistory(_ tracks: [Track]) {
        history.append(contentsOf: tracks)
        let historyCap = historySize()
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
    }

    /// The output failed after loading: mirror the stopped player.
    private func clearStoppedPlaybackState() {
        currentTrack = nil
        currentURL = nil
        playbackState = .stopped
        currentPosition = 0
        duration = 0
        waveformData = []
        stopPositionTimerIfIdle()
        postTrackDidChange()
    }

    private func setQueue(_ newQueue: PlaybackQueue) {
        queue = newQueue
        if queueSnapshot != newQueue { queueSnapshot = newQueue }
    }

    // MARK: - Transport

    /// Play/Pause (toolbar, Playback menu, Dock, media key). During a preview it pauses or
    /// resumes the preview (IMP-W2C-01); never bound to Space (§10 Q1). With nothing loaded
    /// and a queue waiting it continues the queue.
    @MainActor
    func togglePlayPause() {
        if let preview = previewController, preview.isActive {
            preview.togglePause()
            return
        }
        guard currentTrack != nil else {
            if canResumeQueue { Task { await next() } }
            return
        }
        if playbackState != .playing, refuseResumeWhileDiskAway() { return }
        takeGeneration()
        do {
            try audioPlayer.togglePlayPause()
            playbackState = audioPlayer.state
            if playbackState == .playing {
                startPositionTimer()
            } else {
                stopPositionTimerIfIdle()
                updatePosition()
            }
            postStateDidChange()
        } catch {
            AppLogger.shared.log("Playback: play/pause failed: \(error.localizedDescription)", level: .error, source: "Playback")
        }
    }

    /// Play (resume or start).
    @MainActor
    func play() {
        if let preview = previewController, preview.isActive {
            if preview.isPaused { preview.togglePause() }
            return
        }
        guard currentTrack != nil else {
            if canResumeQueue { Task { await next() } }
            return
        }
        resumeMain()
    }

    @MainActor
    private func resumeMain() {
        if playbackState != .playing, refuseResumeWhileDiskAway() { return }
        takeGeneration()
        do {
            try audioPlayer.play()
            playbackState = audioPlayer.state == .playing ? .playing : playbackState
            if playbackState == .playing { startPositionTimer() }
            postStateDidChange()
        } catch {
            AppLogger.shared.log("Playback: resume failed: \(error.localizedDescription)", level: .error, source: "Playback")
        }
    }

    /// Why the loaded main track can't play now, from persisted state and the drive (§15.7);
    /// `nil` when it can. The player shows it under the paused track's title.
    @MainActor
    var currentTrackCantPlay: PlaybackWords.CantPlay? {
        guard let track = currentTrack else { return nil }
        guard PlaybackPlayability.of(track, offlineVolumePath: environment.offlineVolumePath()) == .driveNotConnected else { return nil }
        return .driveNotConnected(volumeName: volumeName(for: track))
    }

    /// Resuming a track whose disk is away would play silence: say so instead (UC-STATUS-07).
    @MainActor
    private func refuseResumeWhileDiskAway() -> Bool {
        guard case .driveNotConnected(let name)? = currentTrackCantPlay else { return false }
        notify(PlaybackWords.cantPlayDriveMessage(name), action: nil)
        return true
    }

    /// Pause.
    @MainActor
    func pause() {
        if let preview = previewController, preview.isActive {
            if !preview.isPaused, !preview.isLoading { preview.togglePause() }
            return
        }
        takeGeneration()
        audioPlayer.pause()
        if currentTrack != nil { playbackState = .paused }
        stopPositionTimerIfIdle()
        updatePosition()
        postStateDidChange()
    }

    /// Stop ⌘.: during a preview it ends the preview only (the main track stays loaded and
    /// paused); otherwise it unloads the main track (and clears a `Can’t play` line).
    @MainActor
    func stop() {
        if let preview = previewController, preview.isActive {
            preview.end(resumeMain: false)
            return
        }
        takeGeneration()
        stopMain()
    }

    /// Unload the main track (no new generation: internal use).
    @MainActor
    private func stopMain() {
        audioPlayer.stop()
        playbackState = .stopped
        currentPosition = 0
        currentTrack = nil
        currentURL = nil
        cantPlay = nil
        endedAwaitingAdvance = false
        waveformData = []
        stopPositionTimerIfIdle()
        postTrackDidChange()
        postStateDidChange()
    }

    /// Seek the audible track (the preview while one runs) to `position` seconds.
    @MainActor
    func seek(to position: TimeInterval) {
        if let preview = previewController, preview.isActive {
            preview.seek(by: position - previewPosition)
            return
        }
        do {
            try audioPlayer.seek(to: position)
            if currentTrack != nil, audioPlayer.state != .stopped { playbackState = audioPlayer.state }
            updatePosition()
        } catch {
            AppLogger.shared.debug("Playback: seek ignored (\(error.localizedDescription))", source: "Playback")
        }
    }

    /// Skip Forward / Back 10 Seconds (⌥⌘→ / ⌥⌘←) on the audible track.
    @MainActor
    func seekBy(_ delta: TimeInterval) {
        if let preview = previewController, preview.isActive {
            preview.seek(by: delta)
            return
        }
        guard hasTrack, duration > 0 else { return }
        seek(to: min(max(0, currentPosition + delta), duration))
    }

    /// Seek to a progress fraction (0…1) of the audible track (the scrubber).
    @MainActor
    func seekToProgress(_ fraction: Double) {
        if let preview = previewController, preview.isActive {
            seek(to: fraction * previewDuration)
            return
        }
        seek(to: fraction * duration)
    }

    /// Set the volume of both players (0…1, clamped) and remember it.
    @MainActor
    func setVolume(_ newVolume: Double) {
        let clamped = min(max(newVolume, 0), 1)
        volume = clamped
        audioPlayer.setVolume(Float(clamped))
        previewPlayer?.setVolume(Float(clamped))
        environment.defaults.set(clamped, forKey: Self.volumeDefaultsKey)
    }

    /// Playback ▸ Repeat.
    @MainActor
    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        repeatMode = mode
        environment.defaults.set(mode.rawValue, forKey: PlaybackRepeatMode.defaultsKey)
    }

    // MARK: - Queue advance (DEC-045, DEC-014, UC-TB-09)

    /// The current track played to its end.
    @MainActor
    func trackDidEnd() {
        // Mark it ended now, so the position poll doesn't report the same end again.
        if playbackState == .playing {
            playbackState = .stopped
            currentPosition = 0
        }
        endedAwaitingAdvance = true
        let ended = currentTrack?.id
        let generation = self.generation
        enqueueTransport { [weak self] in
            await self?.advance(.trackEnded, generation: generation, endedTrackID: ended)
        }
    }

    /// Next ⌘→ (also the media key and the toolbar).
    @MainActor
    func next() async {
        previewController?.abandon()
        let generation = takeGeneration()
        await enqueueTransport { [weak self] in
            await self?.advance(.userNext, generation: generation, endedTrackID: nil)
        }
    }

    /// Advances, Previous and queue jumps run one after another.
    @MainActor
    @discardableResult
    private func enqueueTransport(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = transportChain
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        transportChain = task
        return task
    }

    @MainActor
    private func enqueueTransport(_ work: @escaping @MainActor () async -> Void) async {
        let task: Task<Void, Never> = enqueueTransport(work)
        await task.value
    }

    /// Previous ⌘←: restart after more than 3 s, else the previous playable track.
    @MainActor
    func back() async {
        previewController?.abandon()
        let generation = takeGeneration()
        await enqueueTransport { [weak self] in
            await self?.goBack(generation: generation)
        }
    }

    @MainActor
    private func goBack(generation: Int) async {
        let leaving = currentTrack
        var position = audioPlayer.currentPosition
        var working = history
        var passed: [SkippedTrack] = []
        let verdict = await playabilityVerdict(for: working)
        guard generation == self.generation else { return }
        var failedAtOpen: [Int64: PlaybackPlayability] = [:]
        while true {
            let decision = QueueAdvance.previous(history: working, current: leaving, position: position) { track in
                if let id = track.id, let failed = failedAtOpen[id] { return failed }
                return verdict(track)
            }
            switch decision {
            case .restartCurrent(let skipped):
                if !passed.isEmpty { history = working }
                restartCurrent()
                noteSkipped(passed + skipped)
                return
            case .waitingForDrive(let track):
                if !passed.isEmpty { history = working }
                notify(PlaybackWords.cantPlayDriveMessage(volumeName(for: track)), action: nil)
                return
            case .play(let previous, let proposedHistory, let skipped):
                switch await open(previous, startAt: nil, generation: generation, recordMissing: true, recordHistory: false) {
                case .playing:
                    history = proposedHistory
                    appendHistory([previous])
                    var proposedQueue = queue
                    if let leaving { proposedQueue.pushToFront(leaving) }
                    setQueue(proposedQueue)
                    noteSkipped(passed + skipped)
                    return
                case .superseded:
                    return
                case .unavailable(.driveNotConnected):
                    history = working
                    notify(PlaybackWords.cantPlayDriveMessage(volumeName(for: previous)), action: nil)
                    return
                case .unavailable(let reason):
                    // Drop it and go on to the next earlier one (S8); the leaving track stays.
                    passed += skipped + [SkippedTrack(track: previous, reason: reason)]
                    working = proposedHistory
                    if let id = previous.id { failedAtOpen[id] = reason }
                    position = 0
                case .outputFailed:
                    notify(PlaybackWords.outputFailed(previous.title), action: .tryAgain(previous))
                    return
                }
            }
        }
    }

    @MainActor
    private func restartCurrent() {
        guard currentTrack != nil else { return }
        do {
            try audioPlayer.seek(to: 0)
            currentPosition = 0
            if playbackState != .playing {
                try audioPlayer.play()
                playbackState = .playing
                startPositionTimer()
                postStateDidChange()
            }
        } catch {
            AppLogger.shared.debug("Playback: restart failed (\(error.localizedDescription))", source: "Playback")
        }
    }

    /// Play a specific track from the upcoming queue; everything before it is dropped.
    @MainActor
    func playFromQueue(track: Track) async {
        let generation = takeGeneration()
        await enqueueTransport { [weak self] in
            guard let self else { return }
            var proposed = self.queue
            guard proposed.playFromUpcoming(track) != nil else { return }
            switch await self.open(track, startAt: nil, generation: generation, recordMissing: true) {
            case .playing: self.setQueue(proposed)
            case .superseded: break
            case .unavailable(let reason):
                self.previewController?.end()
                self.reportUnplayable(track, reason)
            case .outputFailed:
                self.previewController?.end()
                self.notify(PlaybackWords.outputFailed(track.title), action: .tryAgain(track))
            }
        }
    }

    /// Insert tracks right after the current track (Play Next ⌥↩). Moves, never duplicates.
    func insertPlayNext(_ tracks: [Track]) {
        var proposed = queue
        proposed.insertPlayNext(tracks)
        setQueue(proposed)
    }

    /// Files missing in a row that stop an advance (a disk returning I/O errors would
    /// otherwise flag the whole context as missing, S2).
    static let missingStreakLimit = 2

    /// One advance run (see `QueueAdvance` for the rule). It commits nothing when the user acted
    /// meanwhile (`generation`) or the ended track is no longer the current one; it waits — and
    /// changes nothing — when the next track's disk is away; it stops after two files missing in
    /// a row and lets the file check judge them instead of flagging them.
    @MainActor
    private func advance(_ trigger: QueueAdvance.Trigger, generation: Int, endedTrackID: Int64?) async {
        guard generation == self.generation else { return }
        if trigger == .trackEnded {
            guard endedAwaitingAdvance, currentTrack?.id == endedTrackID else { return }
        }
        var working = queue
        var failedAtOpen: [Int64: PlaybackPlayability] = [:]
        var failedWithoutID: [Track] = []
        var skipped: [SkippedTrack] = []
        var missingAtOpen: [Track] = []
        var queueBeforeMissing: PlaybackQueue?
        let ids = Set((working.upcoming + working.cycle + [currentTrack].compactMap { $0 }).compactMap(\.id))
        let fresh = await environment.freshTracks(ids)
        guard generation == self.generation else { return }
        let offline = environment.offlineVolumePath()
        let verdict: (Track) -> PlaybackPlayability = { track in
            if let id = track.id, let failed = failedAtOpen[id] { return failed }
            if track.id == nil, failedWithoutID.contains(track) { return .unreadable }
            let latest = track.id.flatMap { fresh[$0] } ?? track
            return PlaybackPlayability.of(latest, offlineVolumePath: offline)
        }
        for _ in 0..<10_000 {
            let result = QueueAdvance.next(queue: working, current: currentTrack, repeatMode: repeatMode,
                                           trigger: trigger, playability: verdict)
            if let waiting = result.waitingForDrive {
                commit(working, passed: skipped)
                waitForDrive(waiting, trigger: trigger)
                recordMissing(missingAtOpen)
                return
            }
            for item in result.skipped where !skipped.contains(where: { $0.track.id != nil && $0.track.id == item.track.id }) {
                skipped.append(item)
            }
            guard let candidate = result.track else {
                commit(result.queue, passed: skipped)
                recordMissing(missingAtOpen)
                finishWithNothingPlayable(skipped)
                return
            }
            let latest = candidate.id.flatMap { fresh[$0] } ?? candidate
            let openResult = await open(latest, startAt: nil, generation: generation, recordMissing: false,
                                        recordHistory: !result.repeatsCurrent)
            switch openResult {
            case .superseded:
                return
            case .playing:
                // Passed-over tracks go to History before the one that plays.
                if !result.repeatsCurrent, let played = history.popLast() {
                    commit(result.queue, passed: skipped)
                    appendHistory([played])
                } else {
                    commit(result.queue, passed: skipped)
                }
                recordMissing(missingAtOpen)
                noteSkipped(skipped)
                return
            case .unavailable(.driveNotConnected):
                // The persisted state didn't know yet: still a wait — the track stays at the head.
                var waitingQueue = result.queue
                waitingQueue.pushToFront(candidate)
                commit(waitingQueue, passed: skipped)
                waitForDrive(latest, trigger: trigger)
                recordMissing(missingAtOpen)
                return
            case .unavailable(let reason):
                if reason == .fileMissing {
                    if queueBeforeMissing == nil {
                        var beforeMissing = result.queue
                        beforeMissing.pushToFront(candidate)
                        queueBeforeMissing = beforeMissing
                    }
                    missingAtOpen.append(latest)
                    if missingAtOpen.count >= Self.missingStreakLimit {
                        tripMissingBreaker(missingAtOpen, queue: queueBeforeMissing ?? working,
                                           passed: skipped, trigger: trigger)
                        return
                    }
                }
                skipped.append(SkippedTrack(track: latest, reason: reason))
                if let id = candidate.id { failedAtOpen[id] = reason } else { failedWithoutID.append(candidate) }
                working = result.queue
            case .outputFailed:
                commit(result.queue, passed: skipped)
                recordMissing(missingAtOpen)
                notify(PlaybackWords.outputFailed(latest.title), action: .tryAgain(latest))
                noteSkipped(skipped)
                return
            }
        }
        // Unreachable in practice (every round consumes an item); never spin.
        commit(working, passed: skipped)
    }

    /// Commit an advance: the queue, and the passed-over tracks into History (they keep their
    /// state word there — never deleted from what the user queued).
    @MainActor
    private func commit(_ newQueue: PlaybackQueue, passed: [SkippedTrack]) {
        setQueue(newQueue)
        if !passed.isEmpty { appendHistory(passed.map(\.track)) }
        endedAwaitingAdvance = false
    }

    /// Single files found missing in a finished run are recorded (the monitor checks that the
    /// folder is reachable).
    @MainActor
    private func recordMissing(_ tracks: [Track]) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let environment = self.environment
        Task { @MainActor in
            for id in ids { await environment.recordMissing(id) }
        }
    }

    /// The disk of the next track is away: nothing moves (DEC-014). A track still playing from
    /// a reachable place keeps playing; otherwise the player names the waiting track.
    @MainActor
    private func waitForDrive(_ waiting: Track, trigger: QueueAdvance.Trigger) {
        let name = volumeName(for: waiting)
        if trigger == .userNext, currentTrack != nil {
            notify(PlaybackWords.cantPlayDriveMessage(name), action: nil)
            return
        }
        stopMain()
        cantPlay = CantPlayState(track: waiting, reason: .driveNotConnected(volumeName: name))
    }

    /// Two files missing in a row: stop, flag nothing, let the file check judge (S2).
    @MainActor
    private func tripMissingBreaker(_ missing: [Track], queue: PlaybackQueue, passed: [SkippedTrack],
                                    trigger: QueueAdvance.Trigger) {
        // The missing ones stay queued (unflagged); only tracks passed for other reasons move on.
        commit(queue, passed: passed.filter { item in !missing.contains { $0.id != nil && $0.id == item.track.id } })
        environment.checkFiles(Set(missing.compactMap(\.id)))
        let name = missing.first.flatMap { volumeName(for: $0) }
        if trigger == .trackEnded || currentTrack == nil { stopMain() }
        notify(PlaybackWords.filesUnreadable(name), action: nil)
        AppLogger.shared.log("Playback: \(missing.count) files missing in a row — stopped, handed to the file check",
                             level: .warning, source: "Playback")
    }

    /// The queue is exhausted. Nothing skipped: plain end (`Not playing`). Otherwise playback
    /// stops on a defined state and the player names the first track that couldn't play.
    @MainActor
    private func finishWithNothingPlayable(_ skipped: [SkippedTrack]) {
        stopMain()
        guard let first = skipped.first,
              let words = PlaybackWords.CantPlay(first.reason, volumeName: volumeName(for: first.track)) else { return }
        cantPlay = CantPlayState(track: first.track, reason: words)
        noteSkipped(skipped)
    }

    @MainActor
    private func noteSkipped(_ skipped: [SkippedTrack]) {
        guard let note = PlaybackWords.skipNote(skipped, volumeName: skipped.first.flatMap { volumeName(for: $0.track) }) else { return }
        let action: PlaybackNotice.Action?
        switch note.action {
        case .download(let ids):
            action = .download(skipped.filter { $0.track.id.map(ids.contains) ?? false }.map(\.track))
        case .locate(let id):
            action = skipped.first { $0.track.id == id }.map { .locate($0.track) }
        case nil:
            action = nil
        }
        notify(note.text, action: action)
    }

    /// Persisted verdicts for `tracks` now (fresh rows + the drive).
    @MainActor
    private func playabilityVerdict(for tracks: [Track]) async -> (Track) -> PlaybackPlayability {
        let fresh = await environment.freshTracks(Set(tracks.compactMap(\.id)))
        let offline = environment.offlineVolumePath()
        return { track in
            let latest = track.id.flatMap { fresh[$0] } ?? track
            return PlaybackPlayability.of(latest, offlineVolumePath: offline)
        }
    }

    /// `Can’t play — …` is judged again (S10): the disk came back, or a track's availability
    /// changed (a download finished, Locate File…).
    @MainActor
    func reevaluateCantPlay(diskReturned: Bool) {
        guard let state = cantPlay else { return }
        if diskReturned, case .driveNotConnected = state.reason {
            cantPlay = nil
            return
        }
        guard let id = state.track.id else { return }
        Task { @MainActor in
            let fresh = await environment.freshTracks([id])[id] ?? state.track
            guard cantPlay?.track.id == id else { return }
            let verdict = PlaybackPlayability.of(fresh, offlineVolumePath: environment.offlineVolumePath())
            if verdict.isPlayable {
                cantPlay = nil
            } else if let words = PlaybackWords.CantPlay(verdict, volumeName: volumeName(for: fresh)), words != state.reason {
                cantPlay = CantPlayState(track: fresh, reason: words)
            }
        }
    }

    /// Locate File… pointed a track at its file again: the player stops naming it as missing.
    @MainActor
    func fileWasLocated(trackID: Int64?) {
        guard let trackID, cantPlay?.track.id == trackID else { return }
        cantPlay = nil
    }

    // MARK: - Playing context (⌘L)

    /// A list records where its row is played from, right before playback starts (every way:
    /// Return, Track ▸ Play, the menu's Play / Shuffle ‹view›). `trackID == nil` matches the
    /// next playback whatever it starts with.
    @MainActor
    func willActivate(_ trackID: Int64?, from origin: PlaybackOrigin) {
        pendingOrigin = (trackID, origin)
    }

    private func consumePendingOrigin(for track: Track) -> PlaybackOrigin? {
        defer { pendingOrigin = nil }
        guard let pending = pendingOrigin, pending.trackID == nil || pending.trackID == track.id else { return nil }
        return pending.origin
    }

    private func consumePendingStart(for track: Track) -> TimeInterval? {
        defer { pendingStart = nil }
        guard let pending = pendingStart, pending.trackID == track.id else { return nil }
        return pending.position
    }

    // MARK: - Now Playing

    /// What Control Center, the media keys and the Dock menu show (the preview while one runs).
    @MainActor
    var nowPlaying: NowPlayingSnapshot? {
        if let preview = previewController, preview.isActive, let track = preview.track {
            return NowPlayingSnapshot(trackID: track.id, title: track.title, artist: track.artist, album: track.album,
                                      albumArtist: track.albumArtist, duration: previewDuration, position: previewPosition,
                                      isPlaying: isPlaying)
        }
        guard let track = currentTrack else { return nil }
        return NowPlayingSnapshot(trackID: track.id, title: track.title, artist: track.artist, album: track.album,
                                  albumArtist: track.albumArtist, duration: duration, position: currentPosition,
                                  isPlaying: playbackState == .playing)
    }

    // MARK: - Position timer

    private func startPositionTimer() {
        guard positionTimer == nil else { return }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopPositionTimerIfIdle() {
        guard playbackState != .playing, !previewAudioRunning else { return }
        positionTimer?.invalidate()
        positionTimer = nil
    }

    @MainActor
    private func tick() {
        updatePosition()
        if let previewPlayer, previewController?.isActive == true {
            previewPosition = previewPlayer.currentPosition
            if previewAudioRunning, previewPlayer.state == .stopped {
                previewAudioRunning = false
                previewController?.previewDidFinish()
            }
        }
    }

    /// Read the main position; detect the natural end of the main track.
    @MainActor
    private func updatePosition() {
        currentPosition = audioPlayer.currentPosition
        if audioPlayer.state == .stopped && playbackState == .playing {
            playbackState = .stopped
            currentPosition = 0
            stopPositionTimerIfIdle()
            postStateDidChange()
            trackDidEnd()
        }
    }

// MARK: - Waveform

    static func waveformCacheURL(in directory: URL, trackID: Int64?, fileURL: URL) -> URL {
        if let id = trackID {
            return directory.appendingPathComponent("\(id).bin")
        } else {
            let hash = abs(fileURL.path.hash)
            return directory.appendingPathComponent("hash_\(hash).bin")
        }
    }

    private func extractWaveform(for url: URL, trackID: Int64?) {
        waveformTask?.cancel()
        isLoadingWaveform = true
        let binCount = WaveformHelpers.adaptiveBinCount(duration: audioPlayer.duration)
        let cacheURL = Self.waveformCacheURL(in: waveformCacheDirectory, trackID: trackID, fileURL: url)
        waveformTask = Task.detached(priority: .utility) { [weak self] in
            let peaks = Self.loadPeaks(url: url, binCount: binCount, cacheURL: cacheURL)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.waveformData = peaks
                self.isLoadingWaveform = false
            }
        }
    }

    private func extractPreviewWaveform(for url: URL, trackID: Int64?, duration: TimeInterval) {
        previewWaveformTask?.cancel()
        previewWaveform = []
        let binCount = WaveformHelpers.adaptiveBinCount(duration: duration)
        let cacheURL = Self.waveformCacheURL(in: waveformCacheDirectory, trackID: trackID, fileURL: url)
        previewWaveformTask = Task.detached(priority: .userInitiated) { [weak self] in
            let peaks = Self.loadPeaks(url: url, binCount: binCount, cacheURL: cacheURL)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.previewWaveform = peaks }
        }
    }

    /// Peaks of `url` (0…1), from the per-library cache or decoded and cached. Off the main actor.
    nonisolated static func loadPeaks(url: URL, binCount: Int, cacheURL: URL) -> [Float] {
        if let data = try? Data(contentsOf: cacheURL) {
            let count = data.count / MemoryLayout<Float>.size
            if count == binCount {
                var peaks = [Float](repeating: 0, count: count)
                _ = peaks.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                return peaks
            }
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let totalFrames = file.length
            guard totalFrames > 0, binCount > 0 else { return [] }
            let chunkFrames: AVAudioFrameCount = 65_536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return [] }
            let framesPerBin = max(Int(totalFrames) / binCount, 1)
            var peaks = [Float](repeating: 0, count: binCount)
            file.framePosition = 0
            var index = 0
            while index < Int(totalFrames) {
                if Task.isCancelled { return [] }
                try file.read(into: buffer, frameCount: chunkFrames)
                let count = Int(buffer.frameLength)
                if count == 0 { break }
                guard let channel = buffer.floatChannelData?[0] else { break }
                for i in 0..<count {
                    let bin = min((index + i) / framesPerBin, binCount - 1)
                    let sample = abs(channel[i])
                    if sample > peaks[bin] { peaks[bin] = sample }
                }
                index += count
            }
            let maxPeak = peaks.max() ?? 1
            if maxPeak > 0 { for i in peaks.indices { peaks[i] /= maxPeak } }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? peaks.withUnsafeBytes { Data($0) }.write(to: cacheURL)
            return peaks
        } catch {
            AppLogger.shared.log("Waveform extraction failed for \(url.lastPathComponent): \(error.localizedDescription)",
                                 level: .warning, source: "Playback")
            return []
        }
    }

        // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "—:——" }
        return PlaybackWords.time(seconds)
    }

    /// `playback_history_size` (Settings ▸ Playback), from the injected defaults.
    private func historySize() -> Int {
        let val = environment.defaults.integer(forKey: "playback_history_size")
        return val > 0 ? val : 50
    }

    /// `playback_context_cap`, from the injected defaults.
    func contextCap() -> Int {
        let val = environment.defaults.integer(forKey: "playback_context_cap")
        return val > 0 ? val : 100
    }

    private func postTrackDidChange() {
        NotificationCenter.default.post(
            name: .playbackTrackDidChange,
            object: nil,
            userInfo: currentTrack.flatMap { track in track.id.map { ["trackId": $0] } }
        )
    }

    private func postStateDidChange() {
        NotificationCenter.default.post(name: .playbackStateDidChange, object: nil, userInfo: ["state": playbackState])
    }
}

// MARK: - Preview (P-PREVIEW, DEC-009 as revised by §10 Q1, DEC-010)

extension PlaybackViewModel {
    /// The Space preview. Created on first use; lists talk to it directly (see
    /// `PreviewController`).
    @MainActor
    var preview: PreviewController {
        if let previewController { return previewController }
        let adapter = PreviewAudioAdapter(owner: self)
        let controller = PreviewController(
            port: adapter,
            resolve: { [weak self] track, done in
                Task { @MainActor in
                    guard let self else { return }
                    done(await self.resolvePreview(track))
                }
            },
            schedule: previewSchedule
        )
        controller.onReport = { [weak self] refusal in self?.notify(refusal.message, action: nil) }
        controller.onHandOver = { [weak self] track, position in
            guard let id = track.id else { return }
            self?.pendingStart = position.map { (id, $0) }
        }
        controller.onChange = { [weak self] in self?.previewDidChange() }
        previewAdapter = adapter
        previewController = controller
        return controller
    }

    /// The preview player exists (its engine is kept for a while after a preview, S3).
    var hasPreviewPlayer: Bool { previewPlayer != nil }

    /// File and analysed drop of a track to preview (a use-time check, off the main actor).
    @MainActor
    func resolvePreview(_ track: Track) async -> Result<ResolvedPreview, PreviewResolveFailure> {
        let root = await environment.libraryRoot()
        switch await PlaybackFileResolver.lookupOffMain(track, libraryRoot: root, probe: environment.probe) {
        case .file(let url):
            let drop = await track.id.asyncFlatMap { await self.environment.dropOffset($0) }
            return .success(ResolvedPreview(url: url, dropOffset: drop))
        case .missing:
            if let id = track.id { await environment.recordMissing(id) }
            return .failure(.fileMissing)
        case .driveNotConnected(let volumePath):
            return .failure(.driveNotConnected(volumeName: LibraryDriveState.volumeName(fromVolumePath: volumePath) ?? environment.volumeName()))
        case .noFile:
            return .failure(.notDownloaded)
        }
    }

    @MainActor
    fileprivate func previewDidChange() {
        if previewController?.isActive != true {
            previewWaveformTask?.cancel()
            previewWaveform = []
            previewPosition = 0
            previewDuration = 0
            schedulePreviewRelease()
        } else {
            previewReleaseToken += 1
        }
        stopPositionTimerIfIdle()
        NotificationCenter.default.post(name: .playbackPreviewDidChange, object: nil)
        postStateDidChange()
    }

    /// After the last preview, release the transient player and its audio engine (S3).
    @MainActor
    private func schedulePreviewRelease() {
        guard previewPlayer != nil else { return }
        previewReleaseToken += 1
        let token = previewReleaseToken
        previewSchedule(PreviewController.releaseDelay) { [weak self] in
            guard let self, self.previewReleaseToken == token, self.previewController?.isActive != true else { return }
            self.previewPlayer?.stop()
            (self.previewPlayer as? AudioPlayer)?.shutDownEngine()
            self.previewPlayer = nil
        }
    }

    /// The library disk went away (called by the window's drive handling, the one observer):
    /// a running preview ends without resuming the main track (its file is most likely on the
    /// same disk). Returns whether the main track was playing under the preview, so the window
    /// says `“‹Disk›” was disconnected — playback paused at …` and offers Resume later.
    @MainActor
    @discardableResult
    func endPreviewForDiskLoss() -> Bool {
        guard let preview = previewController, preview.isActive else { return false }
        let mainWasPlaying = preview.machine.session?.main.wasPlaying ?? false
        preview.end(resumeMain: false)
        advanceAfterPreview = false
        return mainWasPlaying
    }

    // Port operations (used by `PreviewAudioAdapter`).

    @MainActor
    fileprivate func captureMainForPreview() -> MainPlaybackSnapshot {
        // The main track just ended and its advance hasn't run: it counts as playing, and the
        // advance runs when the preview ends (not a restart from 0).
        if endedAwaitingAdvance {
            advanceAfterPreview = true
            return MainPlaybackSnapshot(trackID: currentTrack?.id, position: 0, wasPlaying: true)
        }
        advanceAfterPreview = false
        return MainPlaybackSnapshot(trackID: currentTrack?.id, position: audioPlayer.currentPosition, wasPlaying: playbackState == .playing)
    }

    @MainActor
    fileprivate func suspendMainForPreview() {
        // A preview start is a transport action: in-flight advances give up (S1).
        takeGeneration()
        guard playbackState == .playing else { return }
        audioPlayer.pause()
        playbackState = .paused
        updatePosition()
        postStateDidChange()
    }

    /// Resume the main track if it was playing — unless its file went away meanwhile (then it
    /// stops and the player says why). A main track that ended just before the preview advances.
    @MainActor
    fileprivate func restoreMainAfterPreview(_ snapshot: MainPlaybackSnapshot) -> Bool {
        if advanceAfterPreview {
            advanceAfterPreview = false
            guard snapshot.wasPlaying else { return true }
            endedAwaitingAdvance = true
            let ended = currentTrack?.id
            let generation = self.generation
            enqueueTransport { [weak self] in
                await self?.advance(.trackEnded, generation: generation, endedTrackID: ended)
            }
            return true
        }
        guard snapshot.wasPlaying, let track = currentTrack, track.id == snapshot.trackID else { return true }
        if let url = currentURL, !environment.probe.fileExists(url.path) {
            let offline = environment.offlineVolumePath()
            let reason: PlaybackPlayability = PlaybackPlayability.of(track, offlineVolumePath: offline) == .driveNotConnected
                ? .driveNotConnected : .fileMissing
            stop()
            if let words = PlaybackWords.CantPlay(reason, volumeName: environment.volumeName()) {
                cantPlay = CantPlayState(track: track, reason: words)
            }
            if reason == .fileMissing, let id = track.id {
                Task { await environment.recordMissing(id) }
            }
            return false
        }
        if abs(audioPlayer.currentPosition - snapshot.position) > 0.5 {
            try? audioPlayer.seek(to: snapshot.position)
        }
        play()
        return true
    }

    @MainActor
    fileprivate func startPreviewAudio(_ resolved: ResolvedPreview, track: Track?) throws -> TimeInterval {
        let player = previewPlayer ?? makePreviewPlayer()
        if previewPlayer == nil {
            previewPlayer = player
        }
        previewReleaseToken += 1
        player.setVolume(Float(volume))
        do {
            try player.loadFile(at: resolved.url)
        } catch {
            AppLogger.shared.log("Preview: can’t open \(resolved.url.lastPathComponent): \(error.localizedDescription)",
                                 level: .warning, source: "Playback")
            throw PreviewResolveFailure.unreadable
        }
        player.applyLUFSCompensation(lufsI: track?.lufsI)
        let start = PreviewHotSpot.start(dropOffset: resolved.dropOffset, duration: player.duration)
        if start > 0 { try? player.seek(to: start) }
        do {
            try player.play()
        } catch {
            AppLogger.shared.log("Preview: audio output didn’t start: \(error.localizedDescription)", level: .error, source: "Playback")
            throw PreviewResolveFailure.unreadable
        }
        previewAudioRunning = true
        previewDuration = player.duration
        previewPosition = player.currentPosition
        extractPreviewWaveform(for: resolved.url, trackID: track?.id, duration: player.duration)
        startPositionTimer()
        return start
    }

    @MainActor
    fileprivate func stopPreviewAudio() {
        previewAudioRunning = false
        previewPlayer?.stop()
        stopPositionTimerIfIdle()
    }

    @MainActor
    fileprivate func pausePreviewAudio() {
        previewAudioRunning = false
        previewPlayer?.pause()
        previewPosition = previewPlayer?.currentPosition ?? previewPosition
        stopPositionTimerIfIdle()
    }

    @MainActor
    fileprivate func resumePreviewAudio() {
        guard let previewPlayer else { return }
        try? previewPlayer.play()
        previewAudioRunning = previewPlayer.state == .playing
        startPositionTimer()
    }

    @MainActor
    fileprivate func seekPreviewAudio(by delta: TimeInterval) {
        guard let previewPlayer, previewPlayer.duration > 0 else { return }
        let target = min(max(0, previewPlayer.currentPosition + delta), max(previewPlayer.duration - 0.05, 0))
        let wasRunning = previewAudioRunning
        try? previewPlayer.seek(to: target)
        previewAudioRunning = wasRunning && previewPlayer.state == .playing
        previewPosition = previewPlayer.currentPosition
    }

    @MainActor
    fileprivate var previewPlayerPosition: TimeInterval { previewPlayer?.currentPosition ?? 0 }
    @MainActor
    fileprivate var previewPlayerDuration: TimeInterval { previewPlayer?.duration ?? 0 }
}

/// The live `PreviewAudioPort`: the view model's main player and its transient preview player.
@MainActor
final class PreviewAudioAdapter: PreviewAudioPort {
    unowned let owner: PlaybackViewModel

    init(owner: PlaybackViewModel) {
        self.owner = owner
    }

    func captureMain() -> MainPlaybackSnapshot { owner.captureMainForPreview() }
    func suspendMain() { owner.suspendMainForPreview() }
    func restoreMain(_ snapshot: MainPlaybackSnapshot) -> Bool { owner.restoreMainAfterPreview(snapshot) }
    func startPreview(_ resolved: ResolvedPreview) throws -> TimeInterval {
        try owner.startPreviewAudio(resolved, track: owner.preview.track)
    }
    func stopPreview() { owner.stopPreviewAudio() }
    func pausePreview() { owner.pausePreviewAudio() }
    func resumePreview() { owner.resumePreviewAudio() }
    func seekPreview(by delta: TimeInterval) { owner.seekPreviewAudio(by: delta) }
    var previewPosition: TimeInterval { owner.previewPlayerPosition }
    var previewDuration: TimeInterval { owner.previewPlayerDuration }
}

private extension Optional {
    func asyncFlatMap<U>(_ transform: (Wrapped) async -> U?) async -> U? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
