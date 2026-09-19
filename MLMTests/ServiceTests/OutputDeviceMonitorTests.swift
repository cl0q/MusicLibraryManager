import Testing
import Foundation
import CoreAudio
@testable import MLM

/// Unit tests for `OutputDeviceMonitor`'s pure decision function.
///
/// The CoreAudio listener and view model wiring are not testable in a
/// headless environment; the decision logic is isolated into a static
/// function so its branches can be exercised without any audio hardware.
@Suite("OutputDeviceMonitorTests")
struct OutputDeviceMonitorTests {

    typealias Action = OutputDeviceMonitor.DeviceChangeAction

    // MARK: - No change

    @Test("No action when the default device is unchanged")
    func noChangeWhenDeviceUnchanged() {
        let result = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 42,
            newDeviceID: 42
        )
        #expect(result.action == Action.none)
        #expect(result.autoPaused == false)
        #expect(result.rememberedDeviceID == nil)
    }

    // MARK: - Pause on device loss

    @Test("Pause when playing and the default device changes away")
    func pauseWhenDeviceLost() {
        let result = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 42,
            newDeviceID: 99
        )
        #expect(result.action == Action.pause)
        #expect(result.autoPaused == true)
        #expect(result.rememberedDeviceID == 42)
    }

    @Test("No pause when not playing even if device changes")
    func noPauseWhenNotPlaying() {
        let result = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 42,
            newDeviceID: 99
        )
        #expect(result.action == Action.none)
        #expect(result.autoPaused == false)
    }

    @Test("No pause when there is no previous device recorded yet")
    func noPauseWithoutPreviousDevice() {
        let result = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: nil,
            newDeviceID: 99
        )
        #expect(result.action == Action.none)
        #expect(result.autoPaused == false)
    }

    // MARK: - Resume on device return

    @Test("Resume when the remembered device becomes the default again")
    func resumeWhenDeviceReturns() {
        let result = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: true,
            rememberedDeviceID: 42,
            previousDeviceID: 99,
            newDeviceID: 42
        )
        #expect(result.action == Action.resume)
        #expect(result.autoPaused == false)
        #expect(result.rememberedDeviceID == nil)
    }

    @Test("No resume when a different device becomes the default")
    func noResumeWhenDifferentDeviceReturns() {
        let result = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: true,
            rememberedDeviceID: 42,
            previousDeviceID: 99,
            newDeviceID: 7
        )
        #expect(result.action == Action.none)
        // autoPaused stays true — still waiting for the remembered device.
        #expect(result.autoPaused == true)
        #expect(result.rememberedDeviceID == 42)
    }

    // MARK: - User-paused (no phantom resume)

    @Test("No resume when autoPaused flag is cleared by manual pause")
    func noPhantomResumeAfterManualPause() {
        // Simulate: user paused manually → autoPaused was cleared by the
        // playback-state observer. Device now changes back to the one we
        // were playing on before — must NOT resume.
        let result = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 99,
            newDeviceID: 42
        )
        #expect(result.action == Action.none)
        #expect(result.autoPaused == false)
    }

    // MARK: - Idempotent repeat events

    @Test("Repeat device-loss event while already auto-paused is idempotent")
    func idempotentRepeatDeviceLoss() {
        // First loss: pause.
        let first = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 42,
            newDeviceID: 99
        )
        #expect(first.action == Action.pause)

        // Second loss (different new device) while already auto-paused:
        // the decision function should NOT re-pause (isPlaying is now
        // false because we already paused) and should keep the original
        // remembered device.
        let second = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: first.autoPaused,
            rememberedDeviceID: first.rememberedDeviceID,
            previousDeviceID: 99,
            newDeviceID: 7
        )
        #expect(second.action == Action.none)
        #expect(second.autoPaused == true)
        #expect(second.rememberedDeviceID == 42)
    }

    @Test("Repeat device-return event is idempotent")
    func idempotentRepeatDeviceReturn() {
        // After resume, autoPaused is false. If the device "returns"
        // again (no change), nothing should happen.
        let result = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 42,
            newDeviceID: 42
        )
        #expect(result.action == Action.none)
    }

    // MARK: - Sequence: loss → return → loss → return

    @Test("Full round-trip: playing → lose → return → lose → return")
    func fullRoundTrip() {
        // 1. Playing on device 42, device switches to 99 → pause.
        var state = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: false,
            rememberedDeviceID: nil,
            previousDeviceID: 42,
            newDeviceID: 99
        )
        #expect(state.action == Action.pause)

        // 2. Device 42 comes back → resume.
        state = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: state.autoPaused,
            rememberedDeviceID: state.rememberedDeviceID,
            previousDeviceID: 99,
            newDeviceID: 42
        )
        #expect(state.action == Action.resume)
        #expect(state.autoPaused == false)

        // 3. Playing again, device switches to 7 → pause again.
        state = OutputDeviceMonitor.decide(
            isPlaying: true,
            autoPaused: state.autoPaused,
            rememberedDeviceID: state.rememberedDeviceID,
            previousDeviceID: 42,
            newDeviceID: 7
        )
        #expect(state.action == Action.pause)
        #expect(state.rememberedDeviceID == 42)

        // 4. Device 42 comes back → resume again.
        state = OutputDeviceMonitor.decide(
            isPlaying: false,
            autoPaused: state.autoPaused,
            rememberedDeviceID: state.rememberedDeviceID,
            previousDeviceID: 7,
            newDeviceID: 42
        )
        #expect(state.action == Action.resume)
        #expect(state.autoPaused == false)
    }
}
