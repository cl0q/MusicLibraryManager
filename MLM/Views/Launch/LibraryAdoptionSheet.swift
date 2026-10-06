import AppKit
import SwiftUI

/// `Set up your library file` (S-ADOPT, A0 D7, DEC-031): a sheet over the picker while the
/// install from before library files is found. The phases are a list (done · running · to
/// come); `Not Now` returns to the picker, where the old install stays listed as
/// `Main Library (needs setup)`. Cannot be dismissed while it runs (UC-SHEET-08).
struct LibraryAdoptionSheet: View {
    let launch: LibraryLaunchCoordinator

    @State private var name = LibraryPickerRows.legacyName

    private var state: LibraryLaunchCoordinator.AdoptionState { launch.adoptionState }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Set up your library file")
                .font(.headline)
            Text("MLM now keeps your library — tracks, playlists, settings and playlist covers — in a single library file that you can move and back up as one item. MLM backs up first, then copies your library into the new file. Audio files are not moved.")
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(Spacing.xl)
        .frame(width: 470)
        .interactiveDismissDisabled(state.isRunning)
    }

    // MARK: Offer

    @ViewBuilder
    private var offer: some View {
        Form {
            TextField("Name", text: $name)
            Text("Saved as “\(LibraryPackage.fileName(forLibraryName: trimmedName))” in MLM’s folder in your user Library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.columns)
        HStack {
            Spacer()
            Button("Not Now") { Task { await launch.declineAdoption() } }
                .keyboardShortcut(.cancelAction)
            Button("Create Library File") { Task { await launch.adoptLegacyLibrary(named: trimmedName) } }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
    }

    // MARK: Running (S-ADOPT.E06)

    private func running(_ current: LibraryAdoption.Phase) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Self.phases, id: \.phase) { item in
                HStack(spacing: Spacing.s) {
                    Group {
                        if item.phase == current {
                            ProgressView().controlSize(.small)
                        } else if Self.order(item.phase) < Self.order(current) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(item.text)
                        .foregroundStyle(item.phase == current ? .primary
                                         : Self.order(item.phase) < Self.order(current) ? .secondary : .tertiary)
                }
                .accessibilityElement(children: .combine)
            }
            Text("This can’t be interrupted. It usually takes under a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Text("Working…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static let phases: [(phase: LibraryAdoption.Phase, text: String)] = [
        (.backingUp, "Backing up…"),
        (.creatingLibraryFile, "Creating library file…"),
        (.checking, "Checking…"),
    ]

    private static func order(_ phase: LibraryAdoption.Phase) -> Int {
        phases.firstIndex { $0.phase == phase } ?? 0
    }

    // MARK: Result

    private func succeeded(_ result: LibraryAdoption.Result) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label {
                Text("Your library is now stored in “\(result.packageURL.lastPathComponent)”. The previous files were moved to a folder named “\(result.retiredDirectory.lastPathComponent)” — you can delete it once everything looks right.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.packageURL])
                }
                Button("Done") { Task { await launch.finishAdoption() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ details: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label {
                Text("The library file couldn’t be created. Your library was not changed.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            DisclosureGroup("Details") {
                Text(details)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Show Logs") {
                    ActivityRouter.shared.showLogs(for: nil)
                    ActivityRouter.shared.requestWindow(tab: .logs)
                }
                .buttonStyle(.link)
                Spacer()
                Button("Not Now") { Task { await launch.declineAdoption() } }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await launch.adoptLegacyLibrary(named: trimmedName) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
