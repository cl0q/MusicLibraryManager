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
/// - ⌘. (Stop) belongs to a sheet whenever one is up — it cancels it, and never stops playback,
///   even when the sheet has no Cancel button — and to an editing text field (`cancelOperation:`)
///   (UC-KEY-10, UC-KEY-34, UC-KEY-38).
///
/// Only key presses are intercepted; choosing the item with the mouse always runs it. The
/// decision is pure (`decide`) and unit-tested; `KeyEquivalentGuard` only reads AppKit's state.
enum KeyEquivalentDecision: Equatable, Sendable {
    /// Run the menu command.
    case runCommand
    /// Hand the key to the editing text: perform this text command, or nothing.
    case handToText(String?)
    /// Hand the key to the sheet as Cancel.
    case handToSheet

    /// What a key equivalent does, given where the key press went.
    /// - Parameters:
    ///   - isKeyPress: the command came from the keyboard (a mouse choice always runs it).
    ///   - editingText: an editable text field or text view has keyboard focus.
    ///   - sheetIsUp: the key window is a sheet.
    ///   - textMeaning: the selector the key means in text (`nil`: none), or `nil` meaning when
    ///     the key doesn't belong to text at all.
    ///   - sheetKeepsKey: the key belongs to a sheet (⌘.).
    static func decide(
        isKeyPress: Bool,
        editingText: Bool,
        sheetIsUp: Bool,
        textMeaning: String??,
        sheetKeepsKey: Bool
    ) -> KeyEquivalentDecision {
        guard isKeyPress else { return .runCommand }
        if sheetKeepsKey, sheetIsUp { return .handToSheet }
        if editingText, let meaning = textMeaning { return .handToText(meaning) }
        return .runCommand
    }
}

@MainActor
enum KeyEquivalentGuard {
    /// What the key means while a text field is editing.
    enum TextMeaning {
        case textCommand(Selector)
        case nothing

        var selectorName: String? {
            switch self {
            case .textCommand(let selector): NSStringFromSelector(selector)
            case .nothing: nil
            }
        }
    }

    /// `true` when the key press was handed to the editing text (the caller must not act).
    static func keyBelongsToText(_ meaning: TextMeaning) -> Bool {
        perform(decision(textMeaning: .some(meaning.selectorName), sheetKeepsKey: false))
    }

    /// ⌘. Stop: `true` when the key press went to a sheet (Cancel) or to an editing text field
    /// (`cancelOperation:`); the caller must not stop playback.
    static func stopKeyBelongsElsewhere() -> Bool {
        perform(decision(textMeaning: .some(NSStringFromSelector(#selector(NSResponder.cancelOperation(_:)))),
                         sheetKeepsKey: true))
    }

    private static func decision(textMeaning: String??, sheetKeepsKey: Bool) -> KeyEquivalentDecision {
        let keyWindow = NSApp.keyWindow
        let editingText = (keyWindow?.firstResponder as? NSTextView)?.isEditable == true
        return KeyEquivalentDecision.decide(
            isKeyPress: NSApp.currentEvent?.type == .keyDown,
            editingText: editingText,
            sheetIsUp: keyWindow?.sheetParent != nil,
            textMeaning: textMeaning,
            sheetKeepsKey: sheetKeepsKey
        )
    }

    /// Carries out a decision; `true` when the key was handed away.
    private static func perform(_ decision: KeyEquivalentDecision) -> Bool {
        switch decision {
        case .runCommand:
            return false
        case .handToText(let selectorName):
            if let selectorName, let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                textView.doCommand(by: NSSelectorFromString(selectorName))
            }
            return true
        case .handToSheet:
            // Cancel if the sheet has one; either way the key never stops playback.
            NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
            return true
        }
    }
}
