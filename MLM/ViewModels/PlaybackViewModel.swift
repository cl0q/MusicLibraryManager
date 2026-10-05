import Foundation
import SwiftUI
import AVFoundation

// MARK: - What playback needs from the rest of the app

/// Everything playback reads or reports outside the audio engine, as closures so tests run
/// without a library, a disk or `UserDefaults.standard`. `live` reads `DependencyContainer`.
struct PlaybackEnvironment {
    /// The library folder (`library_root`).
    var libraryRoot: @MainActor () async -> String?
    /// The library disk's `/Volumes/‹name›` while it is not connected; `nil` = connected.
    var offlineVolumePath: @MainActor () -> String?
    /// The library disk's name (`Lexxar`), for sentences.
    var volumeName: @MainActor () -> String?
    /// A use-time check of one path (only when a track is about to play).
    var fileExists: (String) -> Bool
    /// Playback met a missing file while its folder was reachable (W2-A contract:
    /// `LibraryAvailabilityMonitor.recordMissingAtUse`).
    var recordMissing: @MainActor (Int64) async -> Void
    /// The persisted rows of these tracks now (queued copies may be stale: a download may have
    /// finished since they were queued). Missing ids keep their queued copy.
    var freshTracks: @MainActor (Set<Int64>) async -> [Int64: Track]
    /// The analysed drop for the preview hot spot.
    var dropOffset: @MainActor (Int64) async -> Double?
    /// Volume and Repeat are remembered here (app-wide).
    var defaults: UserDefaults

    static func live(configRepository: ConfigRepository?) -> PlaybackEnvironment {
        PlaybackEnvironment(
            libraryRoot: { (try? await configRepository?.getLibraryRoot()) ?? nil },
            offlineVolumePath: {
                let container = DependencyContainer.shared
                return LibraryDriveState.current(container).isOffline ? container.mountObserver?.libraryVolumePath : nil
            },
            volumeName: { LibraryDriveState.current(.shared).volumeName },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            recordMissing: { id in await DependencyContainer.shared.availabilityMonitor?.recordMissingAtUse(trackID: id) },
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

/// A status-bar note from playback (skips, refusals, failures). The window's player shows it
/// in the status bar (`PlayerBar`); the view model never builds UI.
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

/// What Now Playing (Control Center, media keys) shows: the preview while one runs, else the
/// main track.
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
/// - The queue's next track comes from `QueueAdvance` (pure, tested): unplayable tracks are
///   skipped with one status-bar note per skip run; when nothing playable remains the player
///   stops and says why — never a retry loop (fixes PP-MAIN-01).
/// - Failures are words (`PlaybackWords`, §15.7); raw error text only goes to the log
///   (fixes PP-MAIN-15). An unplugged disk is never reported as a file problem (DEC-014).
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

    /// Nothing can play and the player says why (§15.7); cleared by the next playback or Stop.
    private(set) var cantPlay: CantPlayState?

    /// The newest status-bar note (shown once by the window's player).
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

    /// Played tracks, most recent last. Capped by `playback_history_size`.
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
    /// Set by a list right before it activates a row (⌘L returns to it).
    @ObservationIgnored private var pendingOrigin: (trackID: Int64, origin: PlaybackOrigin)?
    /// Return during a preview: the next `playTrack` of this track starts here.
    @ObservationIgnored private var pendingStart: (trackID: Int64, position: TimeInterval)?
    /// The running queue advance (advances are serialized).
    @ObservationIgnored private var advanceChain: Task<Void, Never>?

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
        observers.append(NotificationCenter.default.addObserver(forName: .libraryDriveDidUnmount, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryDiskWentAway() }
        })
    }

    deinit {
        positionTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
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
    /// is left alone and the player or the status bar says why.
    @MainActor
    func playTrack(_ track: Track, queue rows: [Track]) async {
        previewController?.abandon()
        let start = consumePendingStart(for: track)
        let origin = consumePendingOrigin(for: track)
        let proposed = QueueAdvance.start(track, in: rows, queue: queue, cap: Self.contextCap())
        switch await open(track, startAt: start) {
        case .playing:
            setQueue(proposed)
            playingOrigin = origin
        case .unavailable(let reason):
            reportUnplayable(track, reason)
        case .outputFailed:
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
        previewController?.abandon()
        switch loadAndStart(url: url, track: track, startAt: nil) {
        case .playing:
            return true
        case .unavailable(let reason):
            if let track { reportUnplayable(track, reason) }
            return false
        case .outputFailed:
            if let track { notify(PlaybackWords.outputFailed(track.title), action: .tryAgain(track)) }
            return false
        }
    }

    /// The result of trying to open a track.
    enum OpenResult: Equatable {
        case playing
        case unavailable(PlaybackPlayability)
        /// The audio output didn't start — not the track's fault.
        case outputFailed
    }

    /// Find the file (a use-time check), record a missing one, then load and play it.
    @MainActor
    private func open(_ track: Track, startAt: TimeInterval?) async -> OpenResult {
        let root = await environment.libraryRoot()
        switch PlaybackFileResolver.lookup(track, libraryRoot: root, fileExists: environment.fileExists) {
        case .file(let url):
            return loadAndStart(url: url, track: track, startAt: startAt)
        case .missing:
            AppLogger.shared.log("Playback: file missing for track id=\(track.id ?? -1) organized='\(track.organizedPath ?? "")'",
                                 level: .warning, source: "Playback")
            if let id = track.id { await environment.recordMissing(id) }
            return .unavailable(.fileMissing)
        case .driveNotConnected:
            return .unavailable(.driveNotConnected)
        case .noFile:
            return .unavailable(.notDownloaded)
        }
    }

    @MainActor
    private func loadAndStart(url: URL, track: Track?, startAt: TimeInterval?) -> OpenResult {
        do {
            try audioPlayer.loadFile(at: url)
        } catch {
            AppLogger.shared.log("Playback: can’t open \(url.lastPathComponent): \(error.localizedDescription)",
                                 level: .warning, source: "Playback")
            // `loadFile` stops and clears the previous file before it can throw.
            clearStoppedPlaybackState()
            postStateDidChange()
            return .unavailable(.unreadable)
        }
        audioPlayer.applyLUFSCompensation(lufsI: track?.lufsI)
        if let startAt, startAt > 0, startAt < audioPlayer.duration {
            try? audioPlayer.seek(to: startAt)
        }
        do {
            try audioPlayer.play()
        } catch {
            AppLogger.shared.log("Playback: audio output didn’t start: \(error.localizedDescription)",
                                 level: .error, source: "Playback")
            clearStoppedPlaybackState()
            postStateDidChange()
            return .outputFailed
        }
        currentTrack = track
        currentURL = url
        cantPlay = nil
        duration = audioPlayer.duration
        currentPosition = audioPlayer.currentPosition
        playbackState = .playing
        if let track { recordSuccessfulPlayback(track) }
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
        guard let words = PlaybackWords.CantPlay(reason, volumeName: environment.volumeName()) else { return }
        if currentTrack == nil {
            cantPlay = CantPlayState(track: track, reason: words)
        }
        notify(PlaybackWords.couldntPlay(track.title, words), action: Self.fix(for: words, track: track, url: nil))
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

    /// Commit history only after the file loaded and playback really started.
    private func recordSuccessfulPlayback(_ track: Track) {
        history.append(track)
        let historyCap = Self.historySize()
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
    }

    /// A throwing load has already stopped the main player. Mirror that cleared state.
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
    /// resumes the preview (IMP-W2C-01); never bound to Space (§10 Q1).
    @MainActor
    func togglePlayPause() {
        if let preview = previewController, preview.isActive {
            preview.togglePause()
            return
        }
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
        do {
            try audioPlayer.play()
            playbackState = audioPlayer.state == .playing ? .playing : playbackState
            if playbackState == .playing { startPositionTimer() }
            postStateDidChange()
        } catch {
            AppLogger.shared.log("Playback: resume failed: \(error.localizedDescription)", level: .error, source: "Playback")
        }
    }

    /// Pause.
    @MainActor
    func pause() {
        if let preview = previewController, preview.isActive {
            if !preview.isPaused, !preview.isLoading { preview.togglePause() }
            return
        }
        audioPlayer.pause()
        playbackState = .paused
        stopPositionTimerIfIdle()
        updatePosition()
        postStateDidChange()
    }

    /// Stop ⌘.: ends a preview and unloads the main track.
    @MainActor
    func stop() {
        previewController?.abandon()
        audioPlayer.stop()
        playbackState = .stopped
        currentPosition = 0
        currentTrack = nil
        currentURL = nil
        cantPlay = nil
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
            playbackState = audioPlayer.state
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
        let target = min(max(0, currentPosition + delta), duration)
        do {
            try audioPlayer.seek(to: target)
            playbackState = audioPlayer.state
            updatePosition()
        } catch {
            AppLogger.shared.debug("Playback: seek ignored (\(error.localizedDescription))", source: "Playback")
        }
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

    // MARK: - Queue advance (DEC-045, UC-TB-09)

    /// The current track played to its end.
    @MainActor
    func trackDidEnd() {
        // Mark it ended now, so the position poll doesn't report the same end again.
        if playbackState == .playing {
            playbackState = .stopped
            currentPosition = 0
        }
        Task { await enqueueAdvance(.trackEnded) }
    }

    /// Next ⌘→ (also the media key and the toolbar).
    @MainActor
    func next() async {
        previewController?.abandon()
        await enqueueAdvance(.userNext)
    }

    /// Advances run one after another (two quick Nexts skip two tracks, never open one twice).
    @MainActor
    private func enqueueAdvance(_ trigger: QueueAdvance.Trigger) async {
        let previous = advanceChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.advance(trigger)
        }
        advanceChain = task
        await task.value
    }

    /// Previous ⌘←: restart after more than 3 s, else the previous playable track.
    @MainActor
    func back() async {
        previewController?.abandon()
        let position = audioPlayer.currentPosition
        let verdict = await playabilityVerdict(for: history)
        let decision = QueueAdvance.previous(history: history, current: currentTrack, position: position, playability: verdict)
        switch decision {
        case .restartCurrent(let skipped):
            restartCurrent()
            noteSkipped(skipped)
        case .play(let previous, let proposedHistory, let skipped):
            var proposedQueue = queue
            if let current = currentTrack { proposedQueue.pushToFront(current) }
            switch await open(previous, startAt: nil) {
            case .playing:
                // `open` recorded `previous` again; rebuild history without the passed items.
                history = proposedHistory
                recordSuccessfulPlayback(previous)
                setQueue(proposedQueue)
                noteSkipped(skipped)
            case .unavailable(let reason):
                noteSkipped(skipped + [SkippedTrack(track: previous, reason: reason)])
            case .outputFailed:
                notify(PlaybackWords.outputFailed(previous.title), action: .tryAgain(previous))
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
        previewController?.abandon()
        var proposed = queue
        guard proposed.playFromUpcoming(track) != nil else { return }
        switch await open(track, startAt: nil) {
        case .playing: setQueue(proposed)
        case .unavailable(let reason): reportUnplayable(track, reason)
        case .outputFailed: notify(PlaybackWords.outputFailed(track.title), action: .tryAgain(track))
        }
    }

    /// Insert tracks right after the current track (Play Next ⌥↩). Moves, never duplicates.
    func insertPlayNext(_ tracks: [Track]) {
        var proposed = queue
        proposed.insertPlayNext(tracks)
        setQueue(proposed)
    }

    /// One advance run: ask `QueueAdvance` for the next playable track, open it; a track that
    /// turns out unusable at open time is skipped like the others (and a missing file is
    /// recorded). Terminates: each round either plays, stops, or marks one more track failed.
    @MainActor
    private func advance(_ trigger: QueueAdvance.Trigger) async {
        var working = queue
        var failedAtOpen: [Int64: PlaybackPlayability] = [:]
        var skipped: [SkippedTrack] = []
        let fresh = await environment.freshTracks(Set((working.upcoming + working.cycle + [currentTrack].compactMap { $0 }).compactMap(\.id)))
        let offline = environment.offlineVolumePath()
        let verdict: (Track) -> PlaybackPlayability = { track in
            if let id = track.id, let failed = failedAtOpen[id] { return failed }
            let latest = track.id.flatMap { fresh[$0] } ?? track
            return PlaybackPlayability.of(latest, offlineVolumePath: offline)
        }
        while true {
            let result = QueueAdvance.next(queue: working, current: currentTrack, repeatMode: repeatMode,
                                           trigger: trigger, playability: verdict)
            for item in result.skipped where !skipped.contains(where: { $0.track.id != nil && $0.track.id == item.track.id }) {
                skipped.append(item)
            }
            working = result.queue
            guard let candidate = result.track else {
                setQueue(working)
                finishWithNothingPlayable(skipped)
                return
            }
            let latest = candidate.id.flatMap { fresh[$0] } ?? candidate
            switch await open(latest, startAt: nil) {
            case .playing:
                setQueue(working)
                noteSkipped(skipped)
                return
            case .unavailable(let reason):
                skipped.append(SkippedTrack(track: latest, reason: reason))
                guard let id = candidate.id, failedAtOpen[id] == nil else {
                    setQueue(working)
                    finishWithNothingPlayable(skipped)
                    return
                }
                failedAtOpen[id] = reason
            case .outputFailed:
                setQueue(working)
                notify(PlaybackWords.outputFailed(latest.title), action: .tryAgain(latest))
                return
            }
        }
    }

    /// The queue is exhausted. Nothing skipped: plain end (`Not playing`). Otherwise playback
    /// stops on a defined state and the player names the first track that couldn't play.
    @MainActor
    private func finishWithNothingPlayable(_ skipped: [SkippedTrack]) {
        stop()
        guard let first = skipped.first,
              let words = PlaybackWords.CantPlay(first.reason, volumeName: environment.volumeName()) else { return }
        cantPlay = CantPlayState(track: first.track, reason: words)
        noteSkipped(skipped)
    }

    @MainActor
    private func noteSkipped(_ skipped: [SkippedTrack]) {
        guard let note = PlaybackWords.skipNote(skipped, volumeName: environment.volumeName()) else { return }
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

    /// Locate File… pointed a track at its file again: the player stops naming it as missing.
    @MainActor
    func fileWasLocated(trackID: Int64?) {
        guard let trackID, cantPlay?.track.id == trackID else { return }
        cantPlay = nil
    }

    // MARK: - Playing context (⌘L)

    /// A list records where its row is played from, right before activating it.
    @MainActor
    func willActivate(_ trackID: Int64, from origin: PlaybackOrigin) {
        pendingOrigin = (trackID, origin)
    }

    private func consumePendingOrigin(for track: Track) -> PlaybackOrigin? {
        defer { pendingOrigin = nil }
        guard let pending = pendingOrigin, pending.trackID == track.id else { return nil }
        return pending.origin
    }

    private func consumePendingStart(for track: Track) -> TimeInterval? {
        defer { pendingStart = nil }
        guard let pending = pendingStart, pending.trackID == track.id else { return nil }
        return pending.position
    }

    // MARK: - Now Playing

    /// What Control Center and the media keys show (the preview while one runs).
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

    private static func historySize() -> Int {
        let val = UserDefaults.standard.integer(forKey: "playback_history_size")
        return val > 0 ? val : 50
    }

    static func contextCap() -> Int {
        let val = UserDefaults.standard.integer(forKey: "playback_context_cap")
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

    /// File and analysed drop of a track to preview (a use-time check).
    @MainActor
    func resolvePreview(_ track: Track) async -> Result<ResolvedPreview, PreviewResolveFailure> {
        let root = await environment.libraryRoot()
        switch PlaybackFileResolver.lookup(track, libraryRoot: root, fileExists: environment.fileExists) {
        case .file(let url):
            let drop = await track.id.asyncFlatMap { await self.environment.dropOffset($0) }
            return .success(ResolvedPreview(url: url, dropOffset: drop))
        case .missing:
            if let id = track.id { await environment.recordMissing(id) }
            return .failure(.fileMissing)
        case .driveNotConnected(let volumePath):
            return .failure(.driveNotConnected(volumeName: LibraryDriveState.volumeName(fromVolumePath: volumePath) ?? environment.volumeName()))
        case .noFile:
            return .failure(.fileMissing)
        }
    }

    @MainActor
    fileprivate func previewDidChange() {
        if previewController?.isActive != true {
            previewWaveformTask?.cancel()
            previewWaveform = []
            previewPosition = 0
            previewDuration = 0
        }
        stopPositionTimerIfIdle()
        NotificationCenter.default.post(name: .playbackPreviewDidChange, object: nil)
        postStateDidChange()
    }

    /// The library disk went away: a running preview ends; the main track is not resumed
    /// (its file is most likely on the same disk). The window's drive handling says so.
    @MainActor
    func libraryDiskWentAway() {
        guard let preview = previewController, preview.isActive else { return }
        preview.end(resumeMain: false)
    }

    // Port operations (used by `PreviewAudioAdapter`).

    @MainActor
    fileprivate func captureMainForPreview() -> MainPlaybackSnapshot {
        MainPlaybackSnapshot(trackID: currentTrack?.id, position: audioPlayer.currentPosition, wasPlaying: playbackState == .playing)
    }

    @MainActor
    fileprivate func suspendMainForPreview() {
        guard playbackState == .playing else { return }
        audioPlayer.pause()
        playbackState = .paused
        updatePosition()
        postStateDidChange()
    }

    /// Resume the main track if it was playing — unless its file went away meanwhile (then it
    /// stops and the player says why).
    @MainActor
    fileprivate func restoreMainAfterPreview(_ snapshot: MainPlaybackSnapshot) -> Bool {
        guard snapshot.wasPlaying, let track = currentTrack, track.id == snapshot.trackID else { return true }
        if let url = currentURL, !environment.fileExists(url.path) {
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
        // `AudioPlayer.seek` keeps a running player running; a paused one stays put.
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
