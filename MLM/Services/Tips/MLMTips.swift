import AppKit
import Foundation
import SwiftUI
import TipKit

// MARK: - The rule (pure)

/// When a tip may be on screen (UC-KIT-27, THOUGHTS §6): never while a sheet or alert is open and
/// never while a preview plays. Pure, so it is tested with injected inputs.
enum MLMTipGate {
    static func isQuiet(sheetOpen: Bool, previewPlaying: Bool) -> Bool {
        !sheetOpen && !previewPlaying
    }
}

/// Reads the two inputs and tells TipKit when the answer changes. Inputs and the sink are
/// injected; the app wires the windows and the player.
@MainActor
final class MLMTipMonitor {
    private let sheetOpen: () -> Bool
    private let previewPlaying: () -> Bool
    private let apply: (Bool) -> Void
    private(set) var lastQuiet: Bool?
    private var timer: Timer?

    init(sheetOpen: @escaping () -> Bool, previewPlaying: @escaping () -> Bool, apply: @escaping (Bool) -> Void) {
        self.sheetOpen = sheetOpen
        self.previewPlaying = previewPlaying
        self.apply = apply
    }

    /// Recompute; the sink hears about changes only.
    func refresh() {
        let quiet = MLMTipGate.isQuiet(sheetOpen: sheetOpen(), previewPlaying: previewPlaying())
        guard quiet != lastQuiet else { return }
        lastQuiet = quiet
        apply(quiet)
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

// MARK: - The tips

/// Three tips, one at a time and in this order (`TipGroup(.ordered)`): the next one appears
/// after the previous was dismissed.
enum MLMTips {
    /// True while nothing else asks for attention (see `MLMTipGate`); starts false.
    @Parameter static var isQuiet: Bool = false

    static let group = TipGroup(.ordered) {
        PreviewTip()
        DragToPlaylistTip()
        EditSeveralTip()
    }

    static let resetKey = "MLMResetTipsOnNextLaunch"
    @MainActor private static var monitor: MLMTipMonitor?

    /// At launch (`MLMApp`): configure TipKit and start watching sheets and previews.
    @MainActor
    static func configure(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: resetKey) {
            defaults.removeObject(forKey: resetKey)
            try? Tips.resetDatastore()
        }
        do {
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            AppLogger.shared.error("Tips could not start: \(error.localizedDescription)", source: "App")
            return
        }
        let monitor = MLMTipMonitor(
            sheetOpen: { NSApp.windows.contains { $0.attachedSheet != nil } || NSApp.modalWindow != nil },
            previewPlaying: { DependencyContainer.shared.playbackViewModel?.preview.isActive == true },
            apply: { quiet in MLMTips.isQuiet = quiet })
        monitor.start()
        Self.monitor = monitor
    }

    /// Help ▸ Show Tips Again and Settings ▸ Advanced ▸ Show Tips Again (UC-KIT-27). TipKit can
    /// only reset before it is configured, so the reset also runs at the next launch.
    @MainActor
    static func showAgain(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: resetKey)
        try? Tips.resetDatastore()
    }
}

struct PreviewTip: Tip {
    var title: Text { Text("Press Space to preview") }
    var message: Text? { Text("Hear the selected track in the toolbar player without changing the queue.") }
    var rules: [Rule] { #Rule(MLMTips.$isQuiet) { $0 == true } }
}

struct DragToPlaylistTip: Tip {
    var title: Text { Text("Drag tracks onto a playlist") }
    var message: Text? { Text("Drop tracks on a playlist in the sidebar to add them.") }
    var rules: [Rule] { #Rule(MLMTips.$isQuiet) { $0 == true } }
}

struct EditSeveralTip: Tip {
    var title: Text { Text("Edit several tracks at once") }
    var message: Text? { Text("Select more than one track, then choose Edit Info.") }
    var rules: [Rule] { #Rule(MLMTips.$isQuiet) { $0 == true } }
}
