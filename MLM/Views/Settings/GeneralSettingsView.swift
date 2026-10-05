import SwiftUI

/// Settings ▸ General (ST-GENERAL, UC-WIN-04): choices that apply to MLM on this Mac, not to
/// one library. W1-2 moves `Open the last library at launch` here from the Library tab; the
/// opt-in notification setting arrives with W3-SET. There is no Space-bar choice (§10 Q1).
struct GeneralSettingsView: View {
    private var launch: LibraryLaunchCoordinator { LibraryLaunchCoordinator.shared }

    /// The last change didn't reach the library list (registry file); the toggle shows the
    /// value that is actually in effect.
    @State private var saveFailed = false

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
        }
        .formStyle(.grouped)
    }

    /// A save failure is shown, not swallowed (ST-LIB.E04).
    static let saveFailedMessage = "Couldn’t save this setting. MLM keeps the previous choice."
}
