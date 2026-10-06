import AppKit
import SwiftUI

/// Everything the library-file flows present on the main window, in every state: the
/// `New Library` sheet, the open panel for library files, `Switch to “‹name›”?` (listing the
/// work that will stop), the problem alerts (A-LIBFILE-CANTOPEN / -INVALID / A-LIB-COPY /
/// A-LIBFILE-INVALID.N01) and `Quit MLM?` (UC-STATE §15.1, UC-SHEET-11…16, DEC-031/032).
struct LibraryFilePresentation: ViewModifier {
    let launch: LibraryLaunchCoordinator

    private var quit: QuitGuard { QuitGuard.shared }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { launch.newLibraryRequest }, set: { if $0 == nil { launch.cancelNewLibrary() } })) { request in
                NewLibrarySheet(launch: launch, defaultName: request.defaultName)
            }
            .fileImporter(
                isPresented: Binding(get: { launch.libraryFileRequest != nil }, set: { if !$0 { launch.cancelLibraryFile() } }),
                allowedContentTypes: LibraryFileType.importerTypes
            ) { result in
                switch result {
                case .success(let url): Task { await launch.libraryFileChosen(url) }
                case .failure: launch.cancelLibraryFile()
                }
            }
            .fileDialogMessage(LibraryFileType.panelMessage)
            .modifier(SwitchAlert(launch: launch))
            .modifier(ProblemAlert(launch: launch))
            .alert(
                quitTitle,
                isPresented: Binding(get: { quit.question != nil }, set: { if !$0 { quit.cancel() } })
            ) {
                switch quit.question {
                case .confirm?:
                    Button("Quit", role: .destructive) { quit.confirm() }
                    Button("Cancel", role: .cancel) { quit.cancel() }
                        .keyboardShortcut(.defaultAction)
                default:
                    // The one legitimate `OK`: nothing to choose (UC-SHEET-14, review S4).
                    Button("OK", role: .cancel) { quit.cancel() }
                        .keyboardShortcut(.defaultAction)
                }
            } message: {
                if case .confirm(let summary, let libraryName)? = quit.question {
                    Text(summary.message(continuingIn: libraryName) ?? "")
                }
            }
    }

    private var quitTitle: String {
        if case .refuse(let sentence)? = quit.question { return sentence }
        return "Quit MLM?"
    }
}

/// A-LIB-SWITCH (DEC-032, fixes PP-SHELL-16): the work that will stop is read from Activity
/// at the moment of asking and listed. With running work Cancel is the default; with nothing
/// running it is the two-line version and `Switch and Relaunch` is the default (UC-SHEET-15).
private struct SwitchAlert: ViewModifier {
    let launch: LibraryLaunchCoordinator

    func body(content: Content) -> some View {
        let work = RunningWorkSummary(operations: ActivityCenter.shared.activeOperations)
        let name = launch.pendingSwitch?.name ?? ""
        let refusal = work.refusal(libraryName: launch.workSubjectName, switching: true)
        content.alert(
            "Switch to “\(name)”?",
            isPresented: Binding(get: { launch.pendingSwitch != nil }, set: { if !$0 { launch.cancelSwitch() } })
        ) {
            if refusal != nil {
                // Work that must not be cut off runs: only `Cancel` (review S4).
                Button("Cancel", role: .cancel) { launch.cancelSwitch() }
                    .keyboardShortcut(.defaultAction)
            } else if work.isEmpty {
                Button("Switch and Relaunch") { launch.confirmSwitch() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { launch.cancelSwitch() }
            } else {
                Button("Switch and Relaunch", role: .destructive) { launch.confirmSwitch() }
                Button("Cancel", role: .cancel) { launch.cancelSwitch() }
                    .keyboardShortcut(.defaultAction)
            }
        } message: {
            Text(refusal ?? Self.message(name: name, work: work, current: launch.openLibraryName))
        }
    }

    static func message(name: String, work: RunningWorkSummary, current: String?) -> String {
        let lead = "MLM quits and reopens with “\(name)”."
        guard let list = work.message(continuingIn: current) else { return lead }
        return lead + "\n\n" + list
    }
}

/// A library chosen to open that can't be: with a library open always an alert (the open
/// library stays); at launch only the Finder-copy question (the other problems are picker
/// rows and the invalid state).
private struct ProblemAlert: ViewModifier {
    let launch: LibraryLaunchCoordinator

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(get: { launch.switchProblem != nil }, set: { if !$0 { launch.dismissProblem() } })
        ) {
            buttons
        } message: {
            Text(message)
        }
    }

    private var current: String { launch.openLibraryName ?? LibraryFooter.libraryName(launch) }
    private var staysOpen: String {
        launch.screen == .opened ? " “\(current)” stays open." : ""
    }

    private var title: String {
        switch launch.switchProblem {
        case .unavailable(let name, _, _)?, .mismatch(let name, _, _)?, .listNotSaved(let name)?:
            return "“\(name)” can’t be opened"
        case .invalid(let file)?:
            return file.title
        case .duplicateCopy(let name, let originalName, _)?:
            return "“\(name)” is a copy of “\(originalName)”"
        case .creationFailed(let name, _)?:
            return "The library “\(name)” couldn’t be created"
        case .refused(let sentence)?:
            return sentence
        case nil:
            return ""
        }
    }

    private var message: String {
        switch launch.switchProblem {
        case .unavailable(_, let url, .notConnected)?:
            let volume = LibraryPickerRows.volumeName(of: url) ?? ""
            return "The library file is on “\(volume)”, which isn’t connected. Connect the disk, then try again." + staysOpen
        case .unavailable?:
            return "The library file isn’t where MLM last found it. If you moved it, locate it." + staysOpen
        case .mismatch?:
            return "The library file and its database don’t belong together. This can happen when files inside a library file were replaced. MLM didn’t change anything."
        case .invalid(let file)?:
            return file.message
        case .duplicateCopy(_, let originalName, _)?:
            return "To open it, MLM makes the copy a separate library. “\(originalName)” is not changed."
        case .creationFailed(_, let message)?:
            return message
        case .listNotSaved?:
            return "MLM couldn’t update its list of libraries, so nothing changed. Try again."
        case .refused?, nil:
            return ""
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch launch.switchProblem {
        case .unavailable(_, let url, .notConnected)?:
            Button("Try Again") { Task { await launch.handleOpen(url) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { launch.dismissProblem() }
        case .unavailable?:
            Button("Locate…") { launch.chooseLibraryFile() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { launch.dismissProblem() }
        case .mismatch(_, let url, _)?:
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("OK", role: .cancel) { launch.dismissProblem() }
                .keyboardShortcut(.defaultAction)
        case .invalid(let file)?:
            Button("OK", role: .cancel) { launch.dismissProblem() }
                .keyboardShortcut(.defaultAction)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        case .duplicateCopy(_, _, let url)?:
            Button("Open as Separate Library") { Task { await launch.openAsSeparateLibrary(url) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { launch.dismissProblem() }
        case .creationFailed(let name, _)?:
            Button("Choose Another Location…") { launch.requestNewLibrary(named: name) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { launch.dismissProblem() }
        case .listNotSaved?, .refused?, nil:
            Button("OK", role: .cancel) { launch.dismissProblem() }
        }
    }
}
