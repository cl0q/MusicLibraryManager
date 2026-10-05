import Foundation
import SwiftUI

// MARK: - Preview keys of a focused track table (UC-KEY-01/04/05/06, DEC-047, UC-KIT-11)

/// What a key press on the focused track table does for the preview — pure, unit-tested.
///
/// - Space: start / end the preview of the selection. **Never Play/Pause** (§10 Q1). While a
///   type-select is being typed (a letter came less than `typeSelectWindow` ago) Space belongs
///   to the type-select, as in Finder.
/// - Esc: ends a running preview; otherwise it belongs to the next cancellable thing.
/// - ← / →: seek ±5 s only while previewing (hold repeats); otherwise the table's own.
/// - Any modifier (⌘, ⌥, ⌃, ⇧) passes the key on: those are menu keys (⌘← Previous …).
enum TrackListPreviewKey {
    enum Key: Equatable, Sendable {
        case space, escape, leftArrow, rightArrow
    }

    enum Decision: Equatable, Sendable {
        case togglePreview
        case endPreview
        case seek(by: TimeInterval)
        /// Ours, but nothing happens (a held Space doesn't toggle again and again).
        case swallow
        /// Not ours: the table / system handles the key.
        case passOn
    }

    /// A type-select pause longer than this ends it (NSTableView uses about a second).
    static let typeSelectWindow: TimeInterval = 0.9

    static func decide(
        key: Key,
        isRepeat: Bool,
        hasCommandModifiers: Bool,
        isPreviewing: Bool,
        secondsSinceTypeSelect: TimeInterval?
    ) -> Decision {
        guard !hasCommandModifiers else { return .passOn }
        switch key {
        case .space:
            guard !isRepeat else { return .swallow }
            if let elapsed = secondsSinceTypeSelect, elapsed < typeSelectWindow { return .passOn }
            return .togglePreview
        case .escape:
            return isPreviewing && !isRepeat ? .endPreview : .passOn
        case .leftArrow:
            return isPreviewing ? .seek(by: -PreviewController.seekStep) : .passOn
        case .rightArrow:
            return isPreviewing ? .seek(by: PreviewController.seekStep) : .passOn
        }
    }
}

/// Space / Esc / ← / → on the focused table (attached to the `Table` itself, so it only acts
/// while the table has keyboard focus — never from a text field, the sidebar or a button).
struct TrackListPreviewKeys: ViewModifier {
    let actions: TrackListActions
    @State private var typeSelect = TypeSelectClock()
    @Environment(\.container) private var container

    func body(content: Content) -> some View {
        content
            // Letters typed into the table's type-select (UC-TABLE-07): remember when.
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
                if press.modifiers.isDisjoint(with: [.command, .control, .option]) { typeSelect.last = Date() }
                return .ignored
            }
            .onKeyPress(keys: [.space, .escape, .leftArrow, .rightArrow], phases: [.down, .repeat, .up]) { press in
                handle(press)
            }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Esc: the preview's while one runs; a held Esc that ended it stays the preview's.
        if press.key == .escape {
            guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
                  let preview = container.playbackViewModel?.preview else { return .ignored }
            return preview.escapeKey(previewKeyPhase(press.phase)) ? .handled : .ignored
        }
        guard press.phase != .up else { return .ignored }
        let key: TrackListPreviewKey.Key
        switch press.key {
        case .space: key = .space
        case .escape: key = .escape
        case .leftArrow: key = .leftArrow
        case .rightArrow: key = .rightArrow
        default: return .ignored
        }
        let preview = container.playbackViewModel?.preview
        let decision = TrackListPreviewKey.decide(
            key: key,
            isRepeat: press.phase == .repeat,
            hasCommandModifiers: !press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
            isPreviewing: preview?.isActive == true,
            secondsSinceTypeSelect: typeSelect.last.map { Date().timeIntervalSince($0) }
        )
        switch decision {
        case .togglePreview:
            typeSelect.last = nil
            actions.preview()
            return .handled
        case .endPreview:
            preview?.escape()
            return .handled
        case .seek(let delta):
            preview?.seek(by: delta)
            return .handled
        case .swallow:
            return .handled
        case .passOn:
            return .ignored
        }
    }

    /// Reference storage, so recording a key press never re-renders the table.
    final class TypeSelectClock {
        var last: Date?
    }
}

/// SwiftUI's key phase as the preview's.
func previewKeyPhase(_ phase: KeyPress.Phases) -> PreviewController.KeyPhase {
    if phase == .repeat { return .repeat }
    if phase == .up { return .up }
    return .down
}

// MARK: - Window-wide Esc while previewing (UC-KEY-04, W2-C review S4)

/// Esc ends a running preview from anywhere in the main window (the sidebar, Info, a button),
/// before anything else gets the key, and a held Esc never falls through afterwards to clear
/// the search or cancel a sheet. Attached to the window content; active only while a preview
/// runs (no `NSEvent` monitor).
struct PreviewEscapeKey: ViewModifier {
    @Environment(\.container) private var container

    func body(content: Content) -> some View {
        content.onKeyPress(.escape, phases: [.down, .repeat, .up]) { press in
            guard let preview = container.playbackViewModel?.preview,
                  preview.isActive || preview.escapeHeld else { return .ignored }
            return preview.escapeKey(previewKeyPhase(press.phase)) ? .handled : .ignored
        }
    }
}
