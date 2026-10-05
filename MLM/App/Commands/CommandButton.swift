import AppKit
import SwiftUI

// MARK: - Menu items from the catalog

/// One menu-bar item built from `MenuCommand`: catalog title (or a run-time title), the
/// catalog key equivalent, enabled by the caller's state.
///
/// - A **pending** command is always disabled and carries its reason as help text, whatever
///   the caller passes (UC-MENU-02: never hidden, never enabled-but-dead).
/// - A disabled wired command shows `disabledReason` as help when one is given (UC-COPY-13).
struct CommandButton: View {
    let command: MenuCommand
    var title: String? = nil
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    var action: @MainActor () -> Void = {}

    /// A pending command: disabled, with its reason. A wired command needs an action.
    init(_ command: MenuCommand) {
        assert(command.isPending, "\(command) is wired: give it enabled: and an action")
        self.command = command
    }

    init(
        _ command: MenuCommand,
        title: String? = nil,
        enabled: Bool,
        disabledReason: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.command = command
        self.title = title
        self.isEnabled = enabled
        self.disabledReason = disabledReason
        self.action = action
    }

    private var enabled: Bool { isEnabled && !command.isPending }

    var body: some View {
        let button = Button(title ?? command.title) { action() }
            .disabled(!enabled)
            .help(enabled ? "" : (command.pendingReason ?? disabledReason ?? ""))
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut.keyboardShortcut)
        } else {
            button
        }
    }
}

/// A submenu from the catalog (`Export ▸`, `Find ▸`, `Add to Playlist ▸`). A pending submenu
/// is shown disabled and empty.
struct CommandSubmenu<Content: View>: View {
    let command: MenuCommand
    var title: String? = nil
    var isEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    init(_ command: MenuCommand, title: String? = nil, enabled: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.command = command
        self.title = title
        self.isEnabled = enabled
        self.content = content
    }

    var body: some View {
        Menu(title ?? command.title) {
            content()
        }
        .disabled(!isEnabled || command.isPending)
        .help(command.pendingReason ?? "")
    }
}

extension CommandSubmenu where Content == EmptyView {
    /// A pending submenu: present, disabled, empty.
    init(_ command: MenuCommand) {
        self.init(command, enabled: false) { EmptyView() }
    }
}

// MARK: - Keys that text and sheets keep

/// Menu key equivalents win over the focused control in AppKit, so commands whose keys mean
/// something while typing or inside a sheet hand the key back:
///
/// - In an editable text field or text view, ⌘← / ⌘→ / ⌘↑ / ⌘↓ / ⌘⌫ keep their text meaning
///   (line start / end, document start / end, delete to line start) and ⌥⌘← / ⌥⌘→ / ⌥↩ do
///   nothing — playback and track keys never fire while typing (UC-KEY-07, UC-KEY-20,
///   UC-KEY-38).
/// - In a sheet, ⌘. cancels the sheet instead of stopping playback (UC-KEY-10, UC-KEY-34).
///
/// Only key presses are intercepted; choosing the item with the mouse always runs it.
@MainActor
enum KeyEquivalentGuard {
    /// What the key means while a text field is editing.
    enum TextMeaning {
        case textCommand(Selector)
        case nothing
    }

    /// `true` when the key press was handed to the editing text (the caller must not act).
    static func keyBelongsToText(_ meaning: TextMeaning) -> Bool {
        guard isKeyPress, let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable else {
            return false
        }
        if case .textCommand(let selector) = meaning {
            textView.doCommand(by: selector)
        }
        return true
    }

    /// `true` when the key press was handed to a sheet as Cancel (the caller must not act).
    static func keyCancelsSheet() -> Bool {
        guard isKeyPress, let window = NSApp.keyWindow, window.sheetParent != nil else { return false }
        return NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
    }

    private static var isKeyPress: Bool {
        NSApp.currentEvent?.type == .keyDown
    }
}
