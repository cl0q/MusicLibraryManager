import SwiftUI

/// Settings window container.
///
/// Groups all settings sections into a tabbed interface.
struct SettingsView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Einstellungen")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

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
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
