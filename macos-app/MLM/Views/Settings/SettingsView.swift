import SwiftUI

/// Settings window container.
///
/// Groups all settings sections into a tabbed interface.
struct SettingsView: View {
    @Environment(\.container) private var container

    var body: some View {
        TabView {
            LibrarySetupView()
                .tabItem {
                    Label("Library", systemImage: "music.note.house")
                }
                .tag("library")

            MaintenanceView()
                .tabItem {
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
                }
                .tag("maintenance")
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
