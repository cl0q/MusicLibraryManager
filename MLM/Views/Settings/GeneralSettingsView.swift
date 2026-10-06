import SwiftUI

/// Settings ▸ General (ST-GENERAL, UC-WIN-04): choices that apply to MLM on this Mac, not to
/// one library — `Open the last library at launch` (the registry setting, also in the library
/// picker) and the opt-in `Notify me when background work finishes` with what may notify.
/// There is no Space-bar choice (§10 Q1).
struct GeneralSettingsView: View {
    private var launch: LibraryLaunchCoordinator { LibraryLaunchCoordinator.shared }

    /// The last change didn't reach the library list (registry file); the toggle shows the
    /// value that is actually in effect.
    @State private var saveFailed = false
    @AppStorage(ActivitySystemNotifier.settingKey) private var notifyWhenFinished = false
    @AppStorage(ActivitySystemNotifier.Category.importsAndDownloads.rawValue) private var notifyImports = true
    @AppStorage(ActivitySystemNotifier.Category.sync.rawValue) private var notifySync = true
    @AppStorage(ActivitySystemNotifier.Category.backups.rawValue) private var notifyBackups = true

    var body: some View {
        Form {
            Section {
                Toggle("Open the last library at launch", isOn: Binding(
                    get: { launch.rememberLastLibrary },
                    set: { remember in
                        launch.setRememberLastLibrary(remember)
                        saveFailed = launch.rememberLastLibrary != remember
                    }
                ))
                if saveFailed {
                    Text(Self.saveFailedMessage)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Launch")
            } footer: {
                Text("When off, MLM asks which library to open at launch.")
            }
            Section {
                Toggle(isOn: $notifyWhenFinished) {
                    Text("Notify me when background work finishes")
                    Text("Only while MLM is not the front app.")
                }
                .onChange(of: notifyWhenFinished) { _, on in
                    if on { ActivitySystemNotifier.requestPermission() }
                }
                Group {
                    Toggle(ActivitySystemNotifier.Category.importsAndDownloads.title, isOn: $notifyImports)
                    Toggle(ActivitySystemNotifier.Category.sync.title, isOn: $notifySync)
                    Toggle(ActivitySystemNotifier.Category.backups.title, isOn: $notifyBackups)
                }
                .toggleStyle(.checkbox)
                .padding(.leading, Spacing.l)
                .disabled(!notifyWhenFinished)
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
    }

    /// A save failure is shown, not swallowed (ST-LIB.E04).
    static let saveFailedMessage = "Couldn’t save this setting. MLM keeps the previous choice."
}
