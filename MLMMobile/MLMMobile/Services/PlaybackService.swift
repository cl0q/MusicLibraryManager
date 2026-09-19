import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Combine

/// Repeat mode for playback queue.
enum RepeatMode: String, CaseIterable, Equatable {
    case off
    case all
    case one
}

/// A playable item in the queue.
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let trackUUID: String
    let relativePath: String
    var resolvedURL: URL?

    /// Metadata for display (populated from IndexedTrack).
    var title: String = "Unknown"
    var artist: String = "Unknown"
    var album: String = "Unknown"
    var duration: TimeInterval = 0

    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Protocol for player abstraction (enables testing without real audio).
protocol PlayerProtocol: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var rate: Float { get }
    var isPlaying: Bool { get }

    func replaceCurrentItem(with url: URL)
    func play()
    func pause()
    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void)

    func addPeriodicTimeObserver(interval: TimeInterval, queue: DispatchQueue, using block: @escaping (TimeInterval) -> Void) -> Any
    func removeTimeObserver(_ observer: Any)
}

/// AVPlayer wrapper conforming to PlayerProtocol.
final class AVPlayerWrapper: PlayerProtocol {
    private let player: AVPlayer

    init(player: AVPlayer = AVPlayer()) {
        self.player = player
    }

    var currentTime: TimeInterval {
        player.currentTime().seconds
    }

    var duration: TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let d = item.duration.seconds
        return d.isFinite ? d : 0
    }

    var rate: Float {
        player.rate
    }

    var isPlaying: Bool {
        player.rate > 0
    }

    func replaceCurrentItem(with url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion)
    }

    func addPeriodicTimeObserver(interval: TimeInterval, queue: DispatchQueue, using block: @escaping (TimeInterval) -> Void) -> Any {
        let cmTime = CMTime(seconds: interval, preferredTimescale: 600)
        return player.addPeriodicTimeObserver(forInterval: cmTime, queue: queue) { time in
            block(time.seconds)
        }
    }

    func removeTimeObserver(_ observer: Any) {
        player.removeTimeObserver(observer)
    }
}

/// Drives audio playback with queue management, Now Playing integration, and remote commands.
///
/// Uses AVPlayer with manual queue management rather than AVQueuePlayer.
/// Rationale: AVQueuePlayer silently drops `insert(items:after:)` calls when the
/// queue already has items advancing, and makes it awkward to support shuffle/repeat
/// reordering. A single AVPlayer with an index into an in-memory queue gives full
/// control over next/prev/shuffle/repeat-one semantics.
@MainActor
final class PlaybackService: ObservableObject {
    // MARK: - Published state

    @Published var queue: [QueueItem] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var shuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var missingFileNotice: String?
    @Published var currentArtwork: UIImage?

    // MARK: - Private state

    private var player: PlayerProtocol
    private var syncFolder: SyncFolder?
    private var timeObserver: Any?
    private var shuffledIndices: [Int] = []
    private var hasEndedCurrentTrack = false
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(player: PlayerProtocol = AVPlayerWrapper()) {
        self.player = player
        setupAudioSession()
        setupRemoteCommands()
        setupTimeObserver()
        setupInterruptionHandler()
    }

    func configure(syncFolder: SyncFolder) {
        self.syncFolder = syncFolder
    }

    // MARK: - Queue management

    /// Start playback from a list of tracks at a specific index.
    func startPlayback(tracks: [IndexedTrack], startIndex: Int = 0) {
        guard !tracks.isEmpty, startIndex >= 0, startIndex < tracks.count else { return }

        let items = tracks.map { track -> QueueItem in
            var item = QueueItem(
                trackUUID: track.uuid,
                relativePath: track.path
            )
            item.title = track.title
            item.artist = track.artist
            item.album = track.album
            item.duration = TimeInterval(track.duration)
            item.resolvedURL = resolveURL(for: track.path)
            return item
        }

        queue = items
        currentIndex = startIndex
        rebuildShuffleOrder()

        playCurrentItem()
    }

    /// Toggle play/pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Resume playback.
    func play() {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        player.play()
        isPlaying = true
        updateNowPlayingInfoPlaybackRate()
    }

    /// Pause playback.
    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfoPlaybackRate()
    }

    /// Skip to next track.
    func next() {
        guard !queue.isEmpty else { return }
        hasEndedCurrentTrack = false

        if shuffleEnabled {
            if let pos = shuffledIndices.firstIndex(of: currentIndex) {
                let nextPos = pos + 1
                if nextPos < shuffledIndices.count {
                    currentIndex = shuffledIndices[nextPos]
                } else if repeatMode == .all {
                    currentIndex = shuffledIndices[0]
                } else {
                    pause()
                    return
                }
            } else {
                pause()
                return
            }
        } else {
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                currentIndex = nextIndex
            } else if repeatMode == .all {
                currentIndex = 0
            } else {
                pause()
                return
            }
        }

        playCurrentItem()
    }

    /// Skip to previous track (or restart current if > 3 seconds in).
    func previous() {
        guard !queue.isEmpty else { return }
        hasEndedCurrentTrack = false

        if currentTime > 3 {
            seek(to: 0)
            return
        }

        if shuffleEnabled {
            if let pos = shuffledIndices.firstIndex(of: currentIndex) {
                let prevPos = pos - 1
                if prevPos >= 0 {
                    currentIndex = shuffledIndices[prevPos]
                } else if repeatMode == .all {
                    currentIndex = shuffledIndices.last!
                } else {
                    seek(to: 0)
                    return
                }
            }
        } else {
            let prevIndex = currentIndex - 1
            if prevIndex >= 0 {
                currentIndex = prevIndex
            } else if repeatMode == .all {
                currentIndex = queue.count - 1
            } else {
                seek(to: 0)
                return
            }
        }

        playCurrentItem()
    }

    /// Seek to a specific time.
    func seek(to time: TimeInterval) {
        hasEndedCurrentTrack = false
        player.seek(to: time) { [weak self] finished in
            if finished {
                self?.currentTime = time
            }
        }
    }

    /// Jump to a specific queue index.
    func jumpTo(index: Int) {
        guard index >= 0, index < queue.count else { return }
        hasEndedCurrentTrack = false
        currentIndex = index
        playCurrentItem()
    }

    /// Toggle shuffle mode.
    func toggleShuffle() {
        shuffleEnabled.toggle()
        rebuildShuffleOrder()
    }

    /// Cycle through repeat modes: off → all → one → off.
    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }

    // MARK: - URL resolution

    /// Resolve a relative path against the sync folder's music root.
    /// Returns nil if the file does not exist on disk.
    func resolveURL(for relativePath: String) -> URL? {
        guard let musicRoot = syncFolder?.musicRoot else { return nil }
        let url = musicRoot.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Build a QueueItem from an IndexedTrack, resolving its URL.
    func makeQueueItem(from track: IndexedTrack) -> QueueItem {
        var item = QueueItem(
            trackUUID: track.uuid,
            relativePath: track.path
        )
        item.title = track.title
        item.artist = track.artist
        item.album = track.album
        item.duration = TimeInterval(track.duration)
        item.resolvedURL = resolveURL(for: track.path)
        return item
    }

    // MARK: - Now Playing metadata

    /// Build the now-playing info dictionary for the current item.
    func buildNowPlayingInfo(for item: QueueItem) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyAlbumTitle: item.album,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artwork = currentArtwork {
            let mpArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            info[MPMediaItemPropertyArtwork] = mpArtwork
        }
        return info
    }

    // MARK: - Private helpers

    private func rebuildShuffleOrder() {
        if shuffleEnabled {
            shuffledIndices = Array(0..<queue.count).shuffled()
            // Put current track at the front of the shuffled order
            if let currentPos = shuffledIndices.firstIndex(of: currentIndex) {
                shuffledIndices.swapAt(0, currentPos)
            }
        } else {
            shuffledIndices = Array(0..<queue.count)
        }
    }

    private func playCurrentItem() {
        guard currentIndex >= 0, currentIndex < queue.count else { return }

        let item = queue[currentIndex]

        // Check if file exists
        guard let url = item.resolvedURL else {
            missingFileNotice = "File not available: \(item.title)"
            // Auto-skip missing files after a brief delay
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    if self?.missingFileNotice != nil {
                        self?.missingFileNotice = nil
                        self?.next()
                    }
                }
            }
            return
        }

        missingFileNotice = nil
        currentArtwork = nil
        player.replaceCurrentItem(with: url)
        player.play()
        isPlaying = true
        hasEndedCurrentTrack = false
        currentTime = 0
        duration = item.duration

        updateNowPlayingInfo()
        loadArtwork(from: url)
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("PlaybackService: audio session setup failed: \(error)")
        }
    }

    private func setupTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            interval: 0.5,
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time
            if let item = self.queue[safe: self.currentIndex] {
                self.duration = item.duration > 0 ? item.duration : self.player.duration
            }

            // Auto-advance when track ends (guarded to avoid double-fire)
            if !self.hasEndedCurrentTrack,
               self.duration > 0,
               time >= self.duration - 0.5 {
                self.hasEndedCurrentTrack = true
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.play()
                } else {
                    self.next()
                }
            }
        }
    }

    private func setupInterruptionHandler() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            if type == .began {
                self.pause()
            }
        }
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: positionEvent.positionTime)
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: min(self.currentTime + 15, self.duration))
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: max(self.currentTime - 15, 0))
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard currentIndex < queue.count else { return }
        let item = queue[currentIndex]
        let info = buildNowPlayingInfo(for: item)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingInfoPlaybackRate() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(from url: URL) {
        let asset = AVAsset(url: url)
        Task.detached { [weak self] in
            do {
                let metadata = try await asset.load(.commonMetadata)
                for item in metadata {
                    guard item.commonKey == .commonKeyArtwork else { continue }
                    if let data = try await item.load(.dataValue),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            self?.currentArtwork = image
                            self?.updateNowPlayingInfo()
                        }
                        return
                    }
                }
            } catch {
                // Artwork loading is best-effort
            }
        }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
