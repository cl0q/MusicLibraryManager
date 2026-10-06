import SwiftUI

/// The main window's content while no library is open — and during the setup of a new one
/// (UC-WIN-07, UC-EMPTY-09, DEC-031/034): picker, setup, opening, failed, invalid. No sidebar,
/// player or search; the toolbar shows only the title and the Activity item (ContentView).
/// Title `MLM`; the subtitle names the library being set up.
struct LaunchRootView: View {
    let launch: LibraryLaunchCoordinator

    @State private var isSlow = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("MLM")
            .navigationSubtitle(subtitle)
    }

    @ViewBuilder
    private var content: some View {
        switch launch.screen {
        case .picker:
            LibraryPickerView(launch: launch)
        case .firstRunSetup:
            FirstRunSetupView(launch: launch)
        case .loading(let loading):
            LibraryLoadingView(name: loading.name, phase: loading.phase, isSlow: isSlow, onShowLogs: LaunchLogs.show)
                // After 10 s: `… this is taking longer than usual.` with Show Logs (V-LAUNCH-LOADING.N04).
                .task(id: loading.name) {
                    isSlow = false
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled { isSlow = true }
                }
        case .failed(let failure):
            LibraryLaunchFailureView(failure: failure, launch: launch)
        case .invalid(let file):
            InvalidLibraryFileView(file: file, launch: launch)
        case .opened:
            if let setup = launch.setup {
                LibrarySetupStepsView(model: setup, launch: launch)
            } else {
                Color.clear
            }
        case .resolving:
            // Reading the list of libraries takes a moment; nothing to say yet.
            Color.clear
        }
    }

    /// `New library` during step 1, `Setting up “‹name›”` during steps 2–3 (W-MAIN.E01).
    private var subtitle: String {
        switch launch.screen {
        case .firstRunSetup: return "New library"
        case .opened: return launch.setup.map { "Setting up “\($0.libraryName)”" } ?? ""
        default: return ""
        }
    }
}
