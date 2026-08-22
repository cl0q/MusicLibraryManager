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
}
