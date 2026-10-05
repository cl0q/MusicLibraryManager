import Foundation
import Observation

/// State of the trailing column (UC-TRAIL-01): one system `.inspector` with two modes.
///
/// - `toggle(.info)` (⌘I, ⓘ) and `toggle(.queue)` (⌥⌘U, the player's queue button) open the
///   column in their mode, switch an open column to their mode, and close it when it is
///   already open in that mode.
/// - Nothing else opens it (UC-TRAIL-02): no double-click, no play, no selection change.
/// - Open state and mode are remembered across launches.
@MainActor
@Observable
final class TrailingColumnState {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case info
        case queue

        var id: String { rawValue }

        var title: String {
            switch self {
            case .info: "Info"
            case .queue: "Queue"
            }
        }
    }

    static let presentedKey = "shell.trailingColumn.presented"
    static let modeKey = "shell.trailingColumn.mode"

    @ObservationIgnored private let defaults: UserDefaults

    var isPresented: Bool {
        didSet { defaults.set(isPresented, forKey: Self.presentedKey) }
    }

    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPresented = defaults.bool(forKey: Self.presentedKey)
        self.mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .info
    }

    /// Whether the column is visible in `mode` (drives `Show Info` / `Hide Info` titles).
    func isShowing(_ mode: Mode) -> Bool {
        isPresented && self.mode == mode
    }

    /// The only way the column opens: an explicit command in one of its modes.
    func toggle(_ mode: Mode) {
        if isShowing(mode) {
            isPresented = false
        } else {
            self.mode = mode
            isPresented = true
        }
    }
}
