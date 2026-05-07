import SwiftUI

/// Settings window container.
///
/// Groups all settings sections into a tabbed interface.
/// Phase 4 ships with the Library tab only. Phase 17 adds
/// Appearance (theme switching) and Maintenance tabs.
struct SettingsView: View {
    @Environment(\.container) private var container

    var body: some View {
        TabView {
            LibrarySetupView()
                .tabItem {
                    Label("Library", systemImage: "music.note.house")
                }
                .tag("library")
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
