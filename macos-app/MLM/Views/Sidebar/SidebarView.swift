import SwiftUI

/// Sidebar navigation matching the Tauri app's 5-section layout.
///
/// Provides navigation items with ⌘1–⌘5 keyboard shortcuts
/// (wired via CommandMenu in MLMApp) and a Settings footer.
struct SidebarView: View {
    @Binding var selectedSection: SidebarSection
    @Environment(\.container) private var container

    var body: some View {
        List(selection: $selectedSection) {
            Section {
                ForEach(SidebarSection.allCases) { section in
                    HStack {
                        Label(section.label, systemImage: section.icon)

                        // Show disconnected indicator for Library when drive is unmounted
                        if section == .library && !container.isLibraryDriveMounted {
                            Spacer()
                            Circle()
                                .fill(Color.mlmError)
                                .frame(width: 7, height: 7)
                                .help("Library drive disconnected")
                        }
                    }
                    .tag(section)
                }
            } header: {
                Text("NAVIGATION")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkMuted)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            settingsFooter
        }
        .background(Color.mlmSurface)
    }

    // MARK: - Settings footer

    private var settingsFooter: some View {
        Button {
            // Open the Settings window (macOS 13+)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .keyboardShortcut(",")
    }
}
