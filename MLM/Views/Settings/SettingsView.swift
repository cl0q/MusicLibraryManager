import SwiftUI

/// The `Settings` scene's content (W-SETTINGS, UC-WIN-03/04/05, DEC-035): eight tabs in the
/// order of `SettingsTab`, each hosting an existing pane unchanged (their redesign is W3-SET).
///
/// - The selection lives in `SettingsRouter.shared`, so deep links (`openSettings(tab:)`) and
///   ⌘, land on the right tab; the window title is the selected tab's name (system).
/// - With no library open, the tabs that belong to a library are dimmed and one line at the
///   top says so, with `Choose Library…` (UC-WIN-05); General, Playback and Sources keep
///   working.
struct SettingsView: View {
    @Environment(\.container) private var container

    var body: some View {
        @Bindable var router = SettingsRouter.shared
        TabView(selection: $router.selectedTab) {
            pane(.general) { GeneralSettingsView() }
            pane(.library) { LibrarySetupView() }
            pane(.playback) { PlaybackSettingsView() }
            pane(.sources) { SourcesSetupView() }
            pane(.backup) { BackupSettingsView() }
            pane(.storage) { DataLocationsView() }
            pane(.maintenance) { MaintenanceView() }
            pane(.advanced) { AdvancedSettingsView() }
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, minHeight: 500, idealHeight: 560, maxHeight: .infinity)
        .installsMainWindowPresenter()
    }

    /// One tab: the pane, dimmed when it belongs to a library and none is open.
    private func pane<Content: View>(_ tab: SettingsTab, @ViewBuilder content: () -> Content) -> some View {
        let hasLibrary = container.isInitialized
        return content()
            .disabled(tab.belongsToLibrary && !hasLibrary)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !hasLibrary {
                    NoLibraryOpenLine()
                }
            }
            .tabItem {
                Label(tab.title, systemImage: tab.systemImage)
            }
            .tag(tab)
    }
}

/// `No library is open. …` with `Choose Library…` (W-SETTINGS.N01, UC-WIN-05).
private struct NoLibraryOpenLine: View {
    static let message = "No library is open. Settings that belong to a library are dimmed until you open one."

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Button("Choose Library…") {
                if let url = LibraryFilePanel.chooseLibraryFile() {
                    MainWindowPresenter.shared.openLibrary(url, launch: .shared)
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Advanced

/// Settings ▸ Advanced. Until W3-GEN builds the Genres destination, it still hosts the genre
/// tools (formerly the Advanced tab's only content) under a labelled header, so they stay
/// reachable; W3-SET fills Advanced with its designed content (ST-ADVANCED).
private struct AdvancedSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Genres")
                    .font(.headline)
                Text("These genre tools move to Genres in the main window’s sidebar.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            Divider()
            GrooveStudioView()
        }
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
