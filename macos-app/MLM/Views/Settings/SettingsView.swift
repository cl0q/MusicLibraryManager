import SwiftUI

/// Settings window container.
///
/// Groups all settings sections into a tabbed interface.
struct SettingsView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.selectedTab") private var selectedTab = "library"

    var body: some View {
        TabView(selection: $selectedTab) {
            LibrarySetupView()
                .tabItem {
                    Label("Library", systemImage: "music.note.house")
                }
                .tag("library")

            SourcesSetupView()
                .tabItem {
                    Label("Sources", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag("sources")

            MaintenanceView()
                .tabItem {
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
                }
                .tag("maintenance")
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
