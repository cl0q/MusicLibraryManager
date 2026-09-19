import AppKit
import SwiftUI

/// NSApplicationDelegate for lifecycle events.
///
/// Handles app-level events like launch, termination, and dock menu.
class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Lazily-created Settings window. We own this directly via AppKit
    /// because every SwiftUI-native path (Settings scene, Window scene
    /// + openWindow, sheet via NotificationCenter) failed in practice
    /// — Apple's auto Settings menu item ignored our actions.
    private var settingsWindowController: NSWindowController?

    /// Reusable window controller for the remote-playlists browser.
    /// Tracks which source it currently shows so we can focus (not rebuild)
    /// when the same source is requested twice, and replace when a different
    /// source is requested.
    private var remotePlaylistsWindowController: NSWindowController?
    private var remotePlaylistsWindowSource: RemotePlaylistSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set app icon at runtime — ensures Dock shows the correct icon
        // even when macOS icon caches are stale after a rebuild.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        } else if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
                  let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Initialize database on launch
        Task {
            do {
                try await DependencyContainer.shared.initialize()
            } catch {
                print("Failed to initialize: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup on termination
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Settings Window

    /// Open (or focus) the Settings window. Called from the
    /// CommandGroup(replacing: .appSettings) button in MLMApp.
    @MainActor
    func showSettingsWindow() {
        if settingsWindowController == nil {
            let hosting = NSHostingController(
                rootView: SettingsView()
                    .environment(\.container, DependencyContainer.shared)
                    .frame(minWidth: 600, minHeight: 500)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
    }

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
