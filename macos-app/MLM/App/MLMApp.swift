import SwiftUI

/// MLM — Music Library Manager (macOS Native)
///
/// Native SwiftUI rewrite of the Tauri-based Music Library Manager.
/// Shares the same SQLite database and schema for seamless switching
/// between the Tauri and native macOS versions.
@main
struct MLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var container = DependencyContainer.shared

    /// Reads the sidebar selection from the focused window via FocusedValues.
    @FocusedBinding(\.selectedSection) private var selectedSection

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove default New Document item
            CommandGroup(replacing: .newItem) {}

            // ⌘1–5 navigation shortcuts
            CommandMenu("Navigate") {
                ForEach(SidebarSection.allCases) { section in
                    Button(section.label) {
                        selectedSection = section
                    }
                    .keyboardShortcut(section.keyboardShortcut)
                }
            }
        }

        Settings {
            LibrarySetupView()
                .environment(container)
                .frame(minWidth: 500, minHeight: 400)
        }
    }
}
