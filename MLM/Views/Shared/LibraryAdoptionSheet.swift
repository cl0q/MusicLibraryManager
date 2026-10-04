import AppKit
import SwiftUI

/// `Set up your library file` (A3, A0 D7): offered at launch while the pre-A3 layout is in
/// use. Copy: UI-GROUNDTRUTH §3.17 / §5.6.
struct LibraryAdoptionSheet: View {
    let state: LibraryLaunchCoordinator.AdoptionState
    let onCreate: (String) -> Void
    let onNotNow: () -> Void
    let onDone: () -> Void

    @State private var name = "Main Library"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up your library file")
                .font(MLMFont.sectionHeader)
            switch state {
            case .idle:
                offer
            case .running(let phase):
                running(phase)
            case .succeeded(let result):
                succeeded(result)
            case .failed(let details):
                failed(details)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var fileName: String { LibraryPackage.fileName(forLibraryName: trimmedName) }

    private var explanation: some View {
        Text("MLM now keeps your library — tracks, playlists, settings and playlist covers — in a single library file that you can move and back up as one item. MLM backs up first, then copies your library into the new file. Audio files are not moved.")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 12) {
            explanation
            Form {
                TextField("Name", text: $name)
            }
            .formStyle(.columns)
            Text("Saved as \"\(fileName)\" in MLM's folder in your user Library.")
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmInkSecondary)
            HStack {
                Spacer()
                Button("Not now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                Button("Create library file") { onCreate(trimmedName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
    }

    private func running(_ phase: LibraryAdoption.Phase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            explanation
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phaseText(phase))
                    .font(MLMFont.muted)
                    .foregroundStyle(Color.mlmInkSecondary)
            }
        }
    }

    private func phaseText(_ phase: LibraryAdoption.Phase) -> String {
        switch phase {
        case .backingUp: return "Backing up…"
        case .creatingLibraryFile: return "Creating library file…"
        case .checking: return "Checking…"
        }
    }

    private func succeeded(_ result: LibraryAdoption.Result) -> some View {
        let storedName = result.packageURL.lastPathComponent
        return VStack(alignment: .leading, spacing: 12) {
            Text("Your library is now stored in \"\(storedName)\". The previous files were moved to a folder named \"legacy-adopted-…\" — you can delete it once everything looks right.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.packageURL])
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ details: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The library file couldn't be created. Your library was not changed.",
                  systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Details") {
                Text(details)
                    .font(MLMFont.dataSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Not now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                Button("Try again") { onCreate(trimmedName) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
