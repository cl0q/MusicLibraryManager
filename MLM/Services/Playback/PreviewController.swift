import Foundation
import Observation

// MARK: - Ports

/// The audio the preview drives: the main playback (paused and restored around a preview) and
/// a second, transient preview player. `PlaybackViewModel` is the live port; tests use a fake.
@MainActor
protocol PreviewAudioPort: AnyObject {
    /// What the main playback is doing now (before it is paused for a preview).
    func captureMain() -> MainPlaybackSnapshot
    /// Pause the main playback, keeping its position.
    func suspendMain()
    /// Give the main playback back: resume it at its position if it was playing. Returns
    /// `false` when it can't resume (its file or disk went away meanwhile) — the main player
    /// then says why itself.
    @discardableResult
    func restoreMain(_ snapshot: MainPlaybackSnapshot) -> Bool
    /// Open `url` in the preview player and play from the hot spot. Returns the start
    /// position. Throws `PreviewResolveFailure` when the file can't be opened.
    func startPreview(_ resolved: ResolvedPreview) throws -> TimeInterval
    func stopPreview()
    func pausePreview()
    func resumePreview()
    /// Seek the preview by `delta` seconds, clamped to the file.
    func seekPreview(by delta: TimeInterval)
    var previewPosition: TimeInterval { get }
    var previewDuration: TimeInterval { get }
}

// MARK: - Driver

/// Carries out `PreviewMachine` effects: audio through the `PreviewAudioPort`, file lookup
/// through `resolve`, the selection debounce through `schedule`. All three are injected so the
/// tests decide when a lookup answers and when a debounce fires.
///
/// **API for lists** (the shared track table does this; any list of tracks can):
/// - Space: `toggle(owner:candidate:)` with `PreviewCandidate.make(rows:live:)`.
/// - selection changed: `selectionChanged(owner:candidate:)`.
/// - Esc: `escape()` (returns whether it was used); ← / →: `seek(by:)`.
/// - Return / double-click on a row while previewing: `handOver(_:)` before activating it.
@MainActor
@Observable
final class PreviewController {
    /// How long the selection must rest before the preview switches rows (arrow-key repeat
    /// must not thrash the audio engine).
    nonisolated static let settleDelay: Duration = .milliseconds(150)
    /// ← / → while previewing (DEC-047).
    nonisolated static let seekStep: TimeInterval = 5

    private(set) var machine = PreviewMachine()
    /// Where the running preview started (its hot spot).
    private(set) var hotSpot: TimeInterval?

    var isActive: Bool { machine.isActive }
    var track: Track? { machine.track }
    var isLoading: Bool { machine.isLoading }
    var isPaused: Bool { machine.isPaused }

    @ObservationIgnored weak var port: (any PreviewAudioPort)?
    @ObservationIgnored private let resolve: @MainActor (Track, @escaping @MainActor (Result<ResolvedPreview, PreviewResolveFailure>) -> Void) -> Void
    @ObservationIgnored private let schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    /// A refusal sentence for the status bar (UC-STATUS-07).
    @ObservationIgnored var onReport: (@MainActor (PlaybackWords.PreviewRefusal) -> Void)?
    /// Return while previewing: play this track for real, from `position` when given.
    @ObservationIgnored var onHandOver: (@MainActor (Track, TimeInterval?) -> Void)?
    /// The visible state changed (player title area, Now Playing).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - resolve: finds the file and the analysed drop of a track; calls back once.
    ///   - schedule: runs the closure after the delay (live: `Task.sleep`).
    init(
        port: (any PreviewAudioPort)?,
        resolve: @escaping @MainActor (Track, @escaping @MainActor (Result<ResolvedPreview, PreviewResolveFailure>) -> Void) -> Void,
        schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = PreviewController.sleepThenRun
    ) {
        self.port = port
        self.resolve = resolve
        self.schedule = schedule
    }

    nonisolated static func sleepThenRun(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
        }
    }

    // MARK: Events from lists and the player

    func toggle(owner: PreviewOwner, candidate: PreviewCandidate) {
        let main = machine.isActive ? .nothing : (port?.captureMain() ?? .nothing)
        run(machine.toggle(owner: owner, candidate: candidate, main: main))
    }

    @discardableResult
    func escape() -> Bool {
        let result = machine.escape()
        run(result.effects)
        return result.handled
    }

    func selectionChanged(owner: PreviewOwner, candidate: PreviewCandidate) {
        run(machine.selectionChanged(owner: owner, candidate: candidate))
    }

    /// ← / → (`delta` = ±`seekStep`). Returns whether the key was used.
    @discardableResult
    func seek(by delta: TimeInterval) -> Bool {
        let result = machine.seek(by: delta)
        run(result.effects)
        return result.handled
    }

    func togglePause() {
        run(machine.togglePause())
    }

    /// Return while previewing. Returns whether a preview was running (the caller then lets
    /// `onHandOver` play the track instead of its usual activation).
    @discardableResult
    func handOver(_ track: Track) -> Bool {
        guard machine.isActive else { return false }
        run(machine.handOver(track))
        return true
    }

    /// Real playback takes over (Play, Next, Previous, Stop).
    func abandon() {
        run(machine.abandon())
    }

    /// End the preview and restore the main playback; `resumeMain: false` when the library
    /// disk went away (the main track stays paused).
    func end(resumeMain: Bool = true) {
        run(machine.end(resumeMain: resumeMain))
    }

    /// The preview player reached the end of the file.
    func previewDidFinish() {
        guard let token = machine.session?.phase.token else { return }
        run(machine.finished(token: token))
    }

    // MARK: Effects

    private func run(_ effects: [PreviewMachine.Effect]) {
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: PreviewMachine.Effect) {
        switch effect {
        case .suspendMain:
            port?.suspendMain()
        case .resolve(let track, let token):
            hotSpot = nil
            resolve(track) { [weak self] result in
                guard let self else { return }
                self.run(self.machine.resolved(token: token, result))
            }
        case .startAudio(let resolved, let token):
            do {
                hotSpot = try port?.startPreview(resolved)
            } catch {
                let failure = (error as? PreviewResolveFailure) ?? .unreadable
                run(machine.openFailed(token: token, failure))
            }
        case .stopAudio:
            port?.stopPreview()
        case .pauseAudio:
            port?.pausePreview()
        case .resumeAudio:
            port?.resumePreview()
        case .seekAudio(let delta):
            port?.seekPreview(by: delta)
        case .restoreMain(let snapshot):
            hotSpot = nil
            port?.restoreMain(snapshot)
        case .scheduleSettle(let token):
            schedule(Self.settleDelay) { [weak self] in
                guard let self else { return }
                self.run(self.machine.settle(token: token))
            }
        case .report(let refusal):
            onReport?(refusal)
        case .handOver(let track, let fromPreviewPosition):
            let position = fromPreviewPosition ? port?.previewPosition : nil
            port?.stopPreview()
            hotSpot = nil
            onHandOver?(track, position)
        case .changed:
            onChange?()
        }
    }
}
