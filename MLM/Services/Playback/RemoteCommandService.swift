import AppKit
import Foundation
import MediaPlayer
import Combine

/// Wires macOS media keys (play/pause, next, previous) and the Now
/// Playing touch bar / control-center tile to the app's PlaybackViewModel.
///
/// ## Responsibilities
/// - Register handlers on `MPRemoteCommandCenter` for the standard
///   transport commands.
/// - Keep `MPNowPlayingInfoCenter.default().nowPlayingInfo` in sync
///   with the current track and playback state so macOS routes media
///   keys to the app.
/// - Publish the current track's album cover as `MPMediaItemPropertyArtwork`
///   so Control Center, media UI, and Bluetooth displays show the real cover.
///
/// The class is `@MainActor` because `MPRemoteCommandCenter` and
/// `MPNowPlayingInfoCenter` must be touched from the main thread.
@MainActor
final class RemoteCommandService {

    // MARK: - State

    private weak var viewModel: PlaybackViewModel?

    private var trackObserver: NSObjectProtocol?
    private var stateObserver: NSObjectProtocol?
    private var previewObserver: NSObjectProtocol?
    private var positionTimer: Timer?

    /// Track id of the most recent artwork fetch, used to discard stale
    /// results when the track changes while a fetch is in flight.
    private var artworkTrackId: Int64?

    // MARK: - Init

    init() {}

    deinit {
        // deinit runs on whatever thread the last reference is released
        // from; the observers/timer are cleaned up in `stop()`.
    }

    // MARK: - Lifecycle

    /// Begin handling remote commands and publishing now-playing info.
    func start(viewModel: PlaybackViewModel) {
        self.viewModel = viewModel
        registerCommands()
        observeViewModel()
        refreshNowPlayingInfo()
    }

    /// Stop handling remote commands and release observers.
    func stop() {
        unregisterCommands()
        if let trackObserver { NotificationCenter.default.removeObserver(trackObserver) }
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        trackObserver = nil
        stateObserver = nil
        previewObserver = nil
        positionTimer?.invalidate()
        positionTimer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        viewModel = nil
    }

    // MARK: - Remote command registration

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.handlePlay()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTogglePlayPause()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleNextTrack()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handlePreviousTrack()
            return .success
        }
    }

    private func unregisterCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    // MARK: - Command handlers

    private func handlePlay() {
        viewModel?.play()
    }

    private func handlePause() {
        viewModel?.pause()
    }

    private func handleTogglePlayPause() {
        viewModel?.togglePlayPause()
    }

    private func handleNextTrack() {
        Task { [weak self] in
            await self?.viewModel?.next()
        }
    }

    private func handlePreviousTrack() {
        Task { [weak self] in
            await self?.viewModel?.back()
        }
    }

    // MARK: - View model observation

    /// Listen to the existing playback notifications (track + state)
    /// so the Now Playing info stays in sync.
    private func observeViewModel() {
        trackObserver = NotificationCenter.default.addObserver(
            forName: .playbackTrackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNowPlayingInfo() }
        }
        stateObserver = NotificationCenter.default.addObserver(
            forName: .playbackStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNowPlayingInfo()
                self?.updatePositionTimer()
            }
        }
        // A preview shows the previewed track and returns to the main track after (W2-C).
        previewObserver = NotificationCenter.default.addObserver(
            forName: .playbackPreviewDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNowPlayingInfo()
                self?.updatePositionTimer()
            }
        }
        updatePositionTimer()
    }

    // MARK: - Now Playing info

    private func refreshNowPlayingInfo() {
        guard let viewModel else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // The previewed track while a preview runs, else the main track (W2-C).
        guard let now = viewModel.nowPlaying else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            positionTimer?.invalidate()
            positionTimer = nil
            artworkTrackId = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.info(for: now)

        // Kick off async artwork fetch for the new track.
        if let trackId = now.trackID {
            loadArtwork(forTrackId: trackId)
        } else {
            artworkTrackId = nil
        }
    }

    /// The Now Playing dictionary for a snapshot (pure, tested).
    nonisolated static func info(for now: NowPlayingSnapshot) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: now.title,
            MPMediaItemPropertyArtist: now.artist,
            MPMediaItemPropertyAlbumTitle: now.album,
            MPMediaItemPropertyPlaybackDuration: now.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: now.position,
            MPNowPlayingInfoPropertyPlaybackRate: now.isPlaying ? 1.0 : 0.0
        ]
        if !now.albumArtist.isEmpty {
            info[MPMediaItemPropertyAlbumArtist] = now.albumArtist
        }
        return info
    }

    // MARK: - Artwork

    /// Fetch artwork for the given track off the main thread, then update
    /// the now-playing info on the main actor. Reuses the canonical
    /// TrackArtworkCache → AnalysisRepository → disk path.
    private func loadArtwork(forTrackId trackId: Int64) {
        artworkTrackId = trackId
        let repository = DependencyContainer.shared.analysisRepository

        Task.detached(priority: .utility) { [weak self] in
            let image = await Self.loadArtworkImage(
                trackId: trackId,
                repository: repository
            )
            await self?.applyLoadedArtwork(image, forTrackId: trackId)
        }
    }

    /// Discard stale results if the track changed while fetching.
    private func applyLoadedArtwork(_ image: NSImage?, forTrackId trackId: Int64) {
        guard artworkTrackId == trackId else { return }
        applyArtwork(image, forTrackId: trackId)
    }

    /// Resolve the artwork `NSImage` for a track, checking the in-memory
    /// cache first, then falling back to the on-disk cached file via the
    /// analysis repository. Runs off the main actor.
    nonisolated static func loadArtworkImage(
        trackId: Int64,
        repository: AnalysisRepository?
    ) async -> NSImage? {
        // 1. In-memory cache hit (cheap, no disk I/O).
        if let cached = TrackArtworkCache.shared.image(forTrackId: trackId, size: .large) {
            return cached
        }

        // 2. Negative cache — known to have no artwork.
        if TrackArtworkCache.shared.isKnownNoArtwork(trackId: trackId) {
            return nil
        }

        // 3. DB lookup for the artwork path.
        guard let repository else { return nil }
        guard let artworkPath = (try? await repository.fetchArtwork(trackId: trackId))??.artworkPath,
              !artworkPath.isEmpty else {
            TrackArtworkCache.shared.markNoArtwork(trackId: trackId)
            return nil
        }

        // 4. Load from disk.
        let fileURL = URL(fileURLWithPath: artworkPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        guard let image = NSImage(contentsOfFile: fileURL.path) else {
            return nil
        }

        TrackArtworkCache.shared.setImage(image, forTrackId: trackId, size: .large)
        return image
    }

    /// Merge the fetched artwork into the current now-playing info dictionary.
    /// If `image` is nil the artwork key is removed so macOS falls back to
    /// its default brick (no stale cover from the previous track).
    private func applyArtwork(_ image: NSImage?, forTrackId trackId: Int64) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let image {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { [image] requestedSize in
                Self.scaleImage(image, toSize: requestedSize)
            }
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info[MPMediaItemPropertyArtwork] = nil
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Scale an `NSImage` to fill the requested size, preserving aspect
    /// ratio (aspect-fill + center crop) so the artwork looks right in
    /// Control Center's square tile.
    nonisolated static func scaleImage(_ source: NSImage, toSize size: CGSize) -> NSImage {
        let srcSize = source.size
        guard srcSize.width > 0, srcSize.height > 0,
              size.width > 0, size.height > 0 else {
            return source
        }

        // Aspect-fill: compute the scale that covers the target rect.
        let scaleX = size.width / srcSize.width
        let scaleY = size.height / srcSize.height
        let scale = max(scaleX, scaleY)

        let drawWidth = srcSize.width * scale
        let drawHeight = srcSize.height * scale
        let drawOrigin = NSPoint(
            x: (size.width - drawWidth) / 2,
            y: (size.height - drawHeight) / 2
        )
        let drawRect = NSRect(origin: drawOrigin, size: NSSize(width: drawWidth, height: drawHeight))

        let scaled = NSImage(size: size)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: drawRect)
        scaled.unlockFocus()
        return scaled
    }

    /// Tick elapsed time forward while playing so the Now Playing UI
    /// stays accurate between state-change notifications.
    private func updatePositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
        guard let viewModel, viewModel.isPlaying else { return }
        // Update every second; the VM already owns the authoritative
        // position, we just re-publish it.
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let now = self.viewModel?.nowPlaying else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = now.position
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
