import SwiftUI

/// Sidebar navigation matching the Tauri app's 5-section layout.
///
/// Provides navigation items with ⌘1–⌘5 keyboard shortcuts
/// (wired via CommandMenu in MLMApp) and a Settings footer.
struct SidebarView: View {
    @Binding var selectedSection: SidebarSection

    var body: some View {
        List(selection: $selectedSection) {
            Section {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.label, systemImage: section.icon)
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
                .padding(.horizontal, MLMSpacing.sidebarItemPadding)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .keyboardShortcut(",")
    }
}
