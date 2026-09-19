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

            PlaybackSettingsView()
                .tabItem {
                    Label("Playback", systemImage: "play.circle")
                }
                .tag("playback")

            GrooveStudioView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag("advanced")
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Playback Settings

struct PlaybackSettingsView: View {
    @State private var historySize: Int = UserDefaults.standard.integer(forKey: "playback_history_size") > 0
        ? UserDefaults.standard.integer(forKey: "playback_history_size")
        : 50
    @State private var contextCap: Int = UserDefaults.standard.integer(forKey: "playback_context_cap") > 0
        ? UserDefaults.standard.integer(forKey: "playback_context_cap")
        : 100
    @AppStorage("playback_lufs_normalization") private var lufsNormalization: Bool = false

    var body: some View {
        Form {
            Section("History") {
                Stepper(
                    "History size: \(historySize)",
                    value: $historySize,
                    in: 10...500
                )
                .onChange(of: historySize) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "playback_history_size")
                }
            }

            Section("Queue") {
                Stepper(
                    "Queue cap: \(contextCap)",
                    value: $contextCap,
                    in: 10...1000
                )
                .onChange(of: contextCap) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "playback_context_cap")
                }
            }

            Section("Audio") {
                Toggle("Normalize loudness (LUFS)", isOn: $lufsNormalization)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
