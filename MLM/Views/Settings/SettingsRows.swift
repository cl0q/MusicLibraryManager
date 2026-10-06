import AppKit
import SwiftUI

// Shared pieces of the Settings tabs (W3-SET). System fonts, semantic colours; a state is text,
// its symbol is tinted only for success (green) or a problem (orange) — UC-COLOR-05, §15.

/// A path, selectable, in a small monospaced caption (`settings.html` `.path`).
struct SettingsPath: View {
    let path: String

    init(_ path: String) { self.path = path }
    init(_ url: URL) { self.path = (url.path as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        Text(path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
    }
}

/// A state word with its symbol: `Connected`, `Not connected — on “Lexxar”`, `Not found`.
struct SettingsState: View {
    enum Tone { case neutral, ok, problem }

    let text: String
    var systemImage: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(symbolStyle)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
    }

    private var symbolStyle: AnyShapeStyle {
        switch tone {
        case .neutral: AnyShapeStyle(.secondary)
        case .ok: AnyShapeStyle(.green)
        case .problem: AnyShapeStyle(.orange)
        }
    }
}

extension SettingsState {
    /// The state line of a folder (library folder, backup folder, transcode cache).
    init(reach: LocationReach) {
        switch reach {
        case .onThisMac, .connected:
            self.init(text: reach.text, systemImage: reach.systemImage, tone: .ok)
        case .notConnected, .notFound:
            self.init(text: reach.text, systemImage: reach.systemImage, tone: .problem)
        case .notSet:
            self.init(text: reach.text, systemImage: nil, tone: .neutral)
        }
    }
}

/// A row title with its secondary lines (`settings.html` `.fl` + `small`).
struct SettingsRowLabel<Detail: View>: View {
    let title: String
    @ViewBuilder var detail: () -> Detail

    init(_ title: String, @ViewBuilder detail: @escaping () -> Detail) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            VStack(alignment: .leading, spacing: 2) {
                detail()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsRowLabel where Detail == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// `Show in Finder` for a location; disabled with the reason when it can't be reached.
struct ShowInFinderButton: View {
    let url: URL?
    var disabledReason: String?

    var body: some View {
        Button("Show in Finder") {
            guard let url else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            }
        }
        .disabled(url == nil || disabledReason != nil)
        .help(disabledReason ?? "")
    }
}

/// `How to Install` (ST-SRC.N06): the command, `Copy`, and what the tool is needed for — the
/// one popover of the Settings window (UC-SHEET-10).
struct InstallHelpButton: View {
    let row: DownloadToolRow
    @State private var isShown = false

    var body: some View {
        Button("How to Install") { isShown = true }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(row.installTitle).font(.headline)
                    Text(row.installIntro).foregroundStyle(.secondary)
                    HStack {
                        Text(row.installCommand)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.installCommand, forType: .string)
                        }
                    }
                    Text(row.installFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(width: 320)
            }
    }
}

/// A folder chosen in the system panel (UC-SHEET-24/25): `.fileImporter` with its message line.
struct FolderPanel: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    var directory: URL?
    let chosen: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { chosen(url) }
            }
            .fileDialogMessage(message)
            .fileDialogDefaultDirectory(directory)
    }
}

extension View {
    func folderPanel(isPresented: Binding<Bool>, message: String, directory: URL? = nil,
                     chosen: @escaping (URL) -> Void) -> some View {
        modifier(FolderPanel(isPresented: isPresented, message: message, directory: directory, chosen: chosen))
    }

    /// Accepts one folder dropped from Finder on a path row (D-SET-FOLDER-TO-LIBROOT /
    /// D-SET-FOLDER-TO-DESTINATION): the same path as `Change…`.
    func acceptsFolderDrop(enabled: Bool = true, _ chosen: @escaping (URL) -> Void) -> some View {
        dropDestination(for: URL.self, isEnabled: enabled) { urls, _ in
            guard let url = urls.first(where: { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            else { return }
            chosen(url)
        }
    }
}

/// The message of a Maintenance / Library job row while its operation runs: the echo of the
/// Activity operation (UC-JOB-07) with a determinate bar when countable.
struct JobEchoView: View {
    let echo: MaintenanceJobRunner.Echo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(echo.text)
                Button("Show in Activity") { ActivityWindowOpener.open() }
                    .buttonStyle(.link)
            }
            if let fraction = echo.fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 320)
            }
        }
    }
}

/// Opens the Activity window from the Settings window (`openWindow(id: "activity")`).
enum ActivityWindowOpener {
    @MainActor static var action: OpenWindowAction?

    @MainActor static func open(tab: ActivityRouter.Tab = .operations) {
        ActivityRouter.shared.tab = tab
        action?(id: ActivityWindow.id)
    }
}

/// Captures the Settings scene's `openWindow` for `ActivityWindowOpener`.
struct ActivityWindowOpenerInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { ActivityWindowOpener.action = openWindow }
    }
}
