import AppKit
import Observation
import SwiftUI

extension View {
    /// Hands the environment's `openWindow` to `MainWindowPresenter` (main window, Settings).
    func installsMainWindowPresenter() -> some View {
        modifier(MainWindowPresenterInstaller())
    }
}

private struct MainWindowPresenterInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowPresenter.shared.install(openWindow)
        }
    }
}

/// What the library flows want to show in the main window (UC-WIN-01): the switch alert, a
/// problem alert, the New Library sheet.
struct LibraryWindowNeeds: Equatable, Sendable {
    var pendingSwitch = false
    var switchProblem = false
    var newLibraryRequest = false

    /// The main window must come forward when one of them appears.
    static func mustShowWindow(before: LibraryWindowNeeds, after: LibraryWindowNeeds) -> Bool {
        (after.pendingSwitch && !before.pendingSwitch)
            || (after.switchProblem && !before.switchProblem)
            || (after.newLibraryRequest && !before.newLibraryRequest)
    }

    @MainActor
    init(_ launch: LibraryLaunchCoordinator) {
        pendingSwitch = launch.pendingSwitch != nil
        switchProblem = launch.switchProblem != nil
        newLibraryRequest = launch.newLibraryRequest != nil
    }

    init(pendingSwitch: Bool = false, switchProblem: Bool = false, newLibraryRequest: Bool = false) {
        self.pendingSwitch = pendingSwitch
        self.switchProblem = switchProblem
        self.newLibraryRequest = newLibraryRequest
    }
}

/// Brings the one main window forward — reopening it after ⌘W — whenever something must show
/// in it (UC-WIN-01): opening a library file (Finder, Dock, File menu, Settings), New Library…,
/// the switch and problem alerts the library coordinator raises, Remove from Library…, and a
/// Dock-icon click with no window open. Never a second main window: `openWindow(id:)` on a
/// single `Window` scene brings the existing one forward.
@MainActor
final class MainWindowPresenter {
    static let shared = MainWindowPresenter()

    private var openWindow: OpenWindowAction?
    private var needs = LibraryWindowNeeds()

    /// Called from views of the main window and Settings, where the environment has the action.
    func install(_ action: OpenWindowAction) {
        openWindow = action
    }

    /// Activate MLM and bring the main window forward, reopening it if it was closed.
    func show() {
        NSApp.activate()
        if let openWindow {
            openWindow(id: MainWindow.id)
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Library flows

    /// Open a library file (Finder, Dock, File ▸ Open Library… / Open Recent, Settings) — the
    /// window comes forward first, also when the file is the library already open.
    func openLibrary(_ url: URL, launch: LibraryLaunchCoordinator) {
        show()
        Task { await launch.handleOpen(url) }
    }

    /// New Library…: its sheet lives in the main window.
    func requestNewLibrary(launch: LibraryLaunchCoordinator) {
        show()
        launch.requestNewLibrary()
    }

    /// Follow the coordinator: when it raises the switch alert, a problem or the New Library
    /// sheet by any route (a queued Finder open, a retry), bring the window forward.
    func watch(_ launch: LibraryLaunchCoordinator) {
        let current = withObservationTracking {
            LibraryWindowNeeds(launch)
        } onChange: { [weak self] in
            Task { @MainActor in self?.watch(launch) }
        }
        if LibraryWindowNeeds.mustShowWindow(before: needs, after: current) {
            show()
        }
        needs = current
    }
}
