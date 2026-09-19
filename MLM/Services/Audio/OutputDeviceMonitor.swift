import Foundation
import CoreAudio
import Combine

/// Monitors the system default audio output device and decides whether
/// playback should be paused or resumed in response to device changes.
///
/// ## Decision model
/// - While playing, if the default output device changes away from the
///   device that was active, the monitor asks the view model to pause
///   and remembers the lost device (`autoPaused = true`).
/// - If the remembered device becomes the default output again while
///   the monitor is in the `autoPaused` state, it asks the view model
///   to resume and clears the flag.
/// - Manual pause/play by the user clears the `autoPaused` flag so a
///   later device change never causes a phantom resume.
///
/// The CoreAudio listener runs on an arbitrary thread; all view model
/// calls are hopped to `@MainActor`.
final class OutputDeviceMonitor {

    // MARK: - Decision types

    /// Action the monitor should take in response to a device change.
    enum DeviceChangeAction: Equatable {
        /// Pause playback and remember the previous device.
        case pause
        /// Resume playback (the remembered device came back).
        case resume
        /// No action required.
        case none
    }

    // MARK: - Pure decision function (testable)

    /// Decide what to do given the current state and a new default device.
    ///
    /// - Parameters:
    ///   - isPlaying: whether the view model currently reports `.playing`.
    ///   - autoPaused: whether the monitor previously auto-paused.
    ///   - rememberedDeviceID: the device that was active when auto-paused (nil if none).
    ///   - previousDeviceID: the device that was the default before this change.
    ///   - newDeviceID: the new default output device.
    /// - Returns: The action to take and the updated (autoPaused, rememberedDeviceID) pair.
    static func decide(
        isPlaying: Bool,
        autoPaused: Bool,
        rememberedDeviceID: AudioDeviceID?,
        previousDeviceID: AudioDeviceID?,
        newDeviceID: AudioDeviceID
    ) -> (action: DeviceChangeAction, autoPaused: Bool, rememberedDeviceID: AudioDeviceID?) {
        // Device unchanged — nothing to do.
        guard newDeviceID != previousDeviceID else {
            return (.none, autoPaused, rememberedDeviceID)
        }

        // Returning device while we auto-paused → resume.
        if autoPaused, let remembered = rememberedDeviceID, newDeviceID == remembered {
            return (.resume, false, nil)
        }

        // Currently playing and the device is changing away → pause.
        if isPlaying, previousDeviceID != nil, newDeviceID != previousDeviceID {
            return (.pause, true, previousDeviceID)
        }

        // Not playing / no previous device / already auto-paused for a
        // different device — just track the new device for next time.
        return (.none, autoPaused, rememberedDeviceID)
    }

    // MARK: - Instance state

    private weak var viewModel: PlaybackViewModel?

    /// The device that was the default output last time we looked.
    private var previousDeviceID: AudioDeviceID?

    /// The device we paused for — resume target.
    private var rememberedDeviceID: AudioDeviceID?

    /// True when we paused playback ourselves due to device loss.
    private var autoPaused: Bool = false

    /// Token for observing the view model's playback state (clears
    /// `autoPaused` on manual user pause).
    private var stateObservationTask: Task<Void, Never>?

    /// Flag so we don't react to our own pause/resume calls as if the
    /// user had changed something.
    private var isApplyingDeviceAction = false

    // MARK: - Init

    init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Begin monitoring. Must be called on the main actor.
    @MainActor
    func start(viewModel: PlaybackViewModel) {
        self.viewModel = viewModel
        self.previousDeviceID = Self.currentDefaultOutputDeviceID()
        startObservingPlaybackState()
        installListener()
    }

    /// Stop monitoring and release resources.
    func stop() {
        stateObservationTask?.cancel()
        stateObservationTask = nil
        removeListener()
        viewModel = nil
    }

    // MARK: - CoreAudio listener

    private var listenerInstalled = false

    private func installListener() {
        guard !listenerInstalled else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            { _, _, _, inClientData in
                guard let inClientData else { return noErr }
                let monitor = Unmanaged<OutputDeviceMonitor>.fromOpaque(inClientData).takeUnretainedValue()
                monitor.handleDefaultDeviceChanged()
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            listenerInstalled = true
        }
    }

    private func removeListener() {
        guard listenerInstalled else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            { _, _, _, inClientData in
                guard let inClientData else { return noErr }
                let monitor = Unmanaged<OutputDeviceMonitor>.fromOpaque(inClientData).takeUnretainedValue()
                monitor.handleDefaultDeviceChanged()
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        listenerInstalled = false
    }

    // MARK: - Event handling

    /// Called from the CoreAudio callback on an arbitrary thread.
    private func handleDefaultDeviceChanged() {
        let newDeviceID = Self.currentDefaultOutputDeviceID()
        Task { @MainActor [weak self] in
            self?.evaluate(newDeviceID: newDeviceID)
        }
    }

    /// Evaluate the current state against a new default device.
    @MainActor
    private func evaluate(newDeviceID: AudioDeviceID) {
        guard let viewModel else { return }
        guard !isApplyingDeviceAction else {
            // We triggered this change ourselves (e.g. pause stopped the
            // engine which momentarily flipped the default device). Just
            // update the previous-device marker and bail.
            previousDeviceID = newDeviceID
            return
        }

        let result = Self.decide(
            isPlaying: viewModel.isPlaying,
            autoPaused: autoPaused,
            rememberedDeviceID: rememberedDeviceID,
            previousDeviceID: previousDeviceID,
            newDeviceID: newDeviceID
        )
        autoPaused = result.autoPaused
        rememberedDeviceID = result.rememberedDeviceID
        previousDeviceID = newDeviceID

        switch result.action {
        case .pause:
            isApplyingDeviceAction = true
            viewModel.pause()
            isApplyingDeviceAction = false
        case .resume:
            isApplyingDeviceAction = true
            viewModel.play()
            isApplyingDeviceAction = false
        case .none:
            break
        }
    }

    // MARK: - Playback-state observation

    /// Watch the view model's `playbackState` so a manual pause clears
    /// the auto-paused flag (no phantom resume when the user paused).
    @MainActor
    private func startObservingPlaybackState() {
        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self] in
            guard let viewModel = self?.viewModel else { return }
            var lastState = viewModel.playbackState
            while !Task.isCancelled {
                withObservationTracking {
                    _ = viewModel.playbackState
                } onChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.playbackStateDidChange()
                    }
                }
                // Wait until the onChange fires; in practice the observation
                // tracking re-arms via the callback. Use a short sleep as
                // a safety net so the loop doesn't spin if onChange fails
                // to fire.
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let viewModel = self.viewModel else { return }
                let current = viewModel.playbackState
                if current != lastState {
                    lastState = current
                    self.handleStateTransition(current)
                }
            }
        }
    }

    @MainActor
    private func playbackStateDidChange() {
        guard let viewModel else { return }
        handleStateTransition(viewModel.playbackState)
    }

    @MainActor
    private func handleStateTransition(_ newState: AudioPlayer.PlaybackState) {
        // Any state change that is NOT our own device-driven action
        // clears the auto-paused flag so manual pause/play never
        // causes a phantom resume.
        guard !isApplyingDeviceAction else { return }
        autoPaused = false
        rememberedDeviceID = nil
        // If the user stopped, also forget the previous device so we
        // don't auto-resume into a stopped state.
        if newState == .stopped {
            previousDeviceID = Self.currentDefaultOutputDeviceID()
        }
    }

    // MARK: - Helpers

    /// Read the current default output device ID.
    static func currentDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }
}
