import SwiftUI

/// The `Settings` scene's content (W-SETTINGS, UC-WIN-03/04/05, DEC-035): eight tabs in the
/// order of `SettingsTab`, each a native `Form` with `.formStyle(.grouped)` (W3-SET).
///
/// - The selection lives in `SettingsRouter.shared`, so deep links (`openSettings(tab:)`) and
///   ⌘, land on the right tab; the window title is the selected tab's name (system).
/// - With no library open, one line at the top says so, with `Choose Library…` (UC-WIN-05);
///   the tabs that belong to a library are dimmed, the others dim only their per-library
///   sections (General, Playback, Sources, Storage Location and Advanced keep working).
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
        .frame(minWidth: 640, idealWidth: 720, maxWidth: .infinity, minHeight: 500, idealHeight: 620, maxHeight: .infinity)
        .installsMainWindowPresenter()
        .modifier(ActivityWindowOpenerInstaller())
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
            // The library picker fills the main window while no library is open (V-PICKER).
            Button("Choose Library…") {
                MainWindowPresenter.shared.show()
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
