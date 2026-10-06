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

    /// Reusable window controller for the remote-playlists browser.
    /// Tracks which source it currently shows so we can focus (not rebuild)
    /// when the same source is requested twice, and replace when a different
    /// source is requested.
    private var remotePlaylistsWindowController: NSWindowController?
    private var remotePlaylistsWindowSource: RemotePlaylistSource?

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

    // MARK: - Remote Playlists Window

    /// Open (or focus) the remote-playlists browser window for `source`.
    ///
    /// - Same source as currently shown → just focus the existing window.
    /// - Different source → close the old one and build a fresh window.
    /// - No window yet → build one.
    ///
    /// Retain-cycle note: the close closure captures `[weak window]`, not
    /// the hosting controller, so the windowController → hosting → view →
    /// closure → window chain does not leak.
    @MainActor
    func showRemotePlaylistsWindow(source: RemotePlaylistSource) {
        if let existing = remotePlaylistsWindowController,
           remotePlaylistsWindowSource == source {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            return
        }

        // Different source (or first open) — tear down any prior window.
        remotePlaylistsWindowController?.close()
        remotePlaylistsWindowController = nil
        remotePlaylistsWindowSource = nil

        // Build the NSWindow first so the close closure can capture it weakly.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = source.windowTitle
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 620))
        window.center()

        let closeHandler: () -> Void = { [weak window] in
            window?.close()
        }

        let hosting = NSHostingController(
            rootView: RemotePlaylistsView(
                source: source,
                onRequestClose: closeHandler
            )
            .environment(\.container, DependencyContainer.shared)
            .frame(minWidth: 760, minHeight: 620)
        )
        window.contentViewController = hosting

        let controller = NSWindowController(window: window)
        remotePlaylistsWindowController = controller
        remotePlaylistsWindowSource = source

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }
}
