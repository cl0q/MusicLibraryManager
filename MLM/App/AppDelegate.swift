import AppKit
import SwiftUI

/// NSApplicationDelegate for lifecycle events.
///
/// Handles app-level events like launch, termination, and dock menu.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activity's app-level history and the opt-in notifier (W3-ACT).
        ActivityCenter.shared.startForApp()

        // Set app icon at runtime — ensures Dock shows the correct icon
        // even when macOS icon caches are stale after a rebuild.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        } else if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
                  let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Whatever the library coordinator needs to ask happens in the main window: bring it
        // forward (reopening it after ⌘W) when a switch alert, problem or New Library sheet appears.
        MainWindowPresenter.shared.watch(LibraryLaunchCoordinator.shared)

        // Choose and open the library for this launch (A3).
        Task { @MainActor in
            await LibraryLaunchCoordinator.shared.start()
        }
    }

    /// Library files opened in Finder (double-click, Open With) — at launch or while running.
    /// The main window comes forward; the coordinator decides: launch library, open directly,
    /// or ask to switch (A3, A0 D9, UC-WIN-01).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == LibraryPackage.fileExtension }) else { return }
        MainWindowPresenter.shared.openLibrary(url, launch: LibraryLaunchCoordinator.shared)
    }

    /// A Dock-icon click with no window open brings the main window back (UC-WIN-01).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowPresenter.shared.show()
        }
        return true
    }

    /// Quit with work running asks first and lists what stops (PP-SHELL-16, `QuitGuard`);
    /// nothing running quits at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitGuard.shared.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The queue is kept when MLM quits (W2-D): the last save, synchronously.
        DependencyContainer.shared.playbackViewModel?.flushQueuePersistence()
        // Activity's queued history writes: end states and failure ids (W3-ACT S8).
        ActivityCenter.shared.flushBeforeQuit()
    }

    /// Closing the main window (⌘W) does not quit; the Dock icon or Window ▸ MLM brings it back
    /// (UC-WIN-01, M-FILE.E05).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Dock menu (UC-DOCK-01)

    private let dockMenuTarget = DockMenuTarget()

    /// Now playing, Play / Pause, Next, Previous and Open Recent (`DockMenuModel`); the system
    /// appends its own items.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenuBuilder.menu(
            DockMenuBuilder.model(container: .shared, launch: .shared),
            target: dockMenuTarget
        )
    }

    // Settings is the SwiftUI `Settings` scene (MLMApp, DEC-035); deep links go through
    // `openSettings(tab:)` (`SettingsTab.swift`). The AppKit settings window is gone (UC-WIN-03).

    // The remote-playlists window (W-REMOTE) is gone: `Import Playlist from Source…` is a sheet in
    // the main window (S-IMPORT, W3-ADD, DEC-026).
}
