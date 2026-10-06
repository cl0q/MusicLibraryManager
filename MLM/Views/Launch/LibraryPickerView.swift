import AppKit
import SwiftUI

/// The library picker (V-PICKER, DEC-031, THOUGHTS §7.17): fills the main window whenever no
/// library is open. Every library MLM knows, with its state in words (UC-STATE §15.1); a
/// problem with one library is that row's state with its own actions, not a separate screen
/// (replaces V-LAUNCH-NOLIB and the window form of V-LAUNCH-CANTOPEN; fixes PP-SHELL-08).
struct LibraryPickerView: View {
    let launch: LibraryLaunchCoordinator

    @State private var selection: String?
    @State private var facts: [String: LibraryPickerFacts] = [:]

    private var rows: [LibraryPickerRow] { launch.pickerRows }
    private var selectedRow: LibraryPickerRow? { rows.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selectInitialRow() }
        .onChange(of: launch.pickerFocus) { _, _ in selectInitialRow() }
        .onChange(of: rows.map(\.id)) { _, ids in
            if selection.map({ !ids.contains($0) }) ?? true { selectInitialRow() }
        }
        // Availability follows the disks (D-LIBFILE / A0 D5), not computed once at launch.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            launch.refreshPicker()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            launch.refreshPicker()
        }
        .task(id: rows.map(\.id)) { await loadFacts() }
        .sheet(isPresented: Binding(
            get: { launch.adoptionOffer },
            set: { shown in if !shown { Task { await launch.declineAdoption() } } }
        )) {
            LibraryAdoptionSheet(launch: launch)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let focus = launch.pickerFocus {
                Text("“\(focus.name)” can’t be opened")
                    .font(.title2.bold())
                Text("The reason is shown on its row. Fix it there, or open another library.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a library")
                    .font(.title2.bold())
                if !rows.isEmpty {
                    Text("MLM opens one library at a time. Switching later relaunches MLM.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                LibraryPickerRowView(
                    row: row,
                    facts: facts[row.id],
                    isSelected: row.id == selection,
                    note: launch.rowNotes[row.id],
                    launch: launch
                )
                .tag(row.id)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(minHeight: 180)
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                rowMenu(row)
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }), row.canOpen {
                Task { await launch.openRow(row) }
            }
        }
        .onDeleteCommand {
            if let row = selectedRow { launch.removeFromList(row) }
        }
        .accessibilityLabel("Libraries")
    }

    /// V-PICKER.N14: primary, locate, remove.
    @ViewBuilder
    private func rowMenu(_ row: LibraryPickerRow) -> some View {
        Button("Open") { Task { await launch.openRow(row) } }
            .disabled(!row.canOpen)
        if row.kind == .legacy {
            Button("Set Up…") { launch.offerAdoption() }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            .disabled(!FileManager.default.fileExists(atPath: row.url.path))
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.url.path, forType: .string)
        }
        if row.state == .notFound {
            Button("Locate…") { launch.locate(row) }
        }
        if row.isRegistered || row.kind == .unlisted {
            Divider()
            Button("Remove from List") { launch.removeFromList(row) }
        }
    }

    // MARK: Empty (V-PICKER.N12)

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No libraries yet")
            } icon: {
                LibraryFileIcon.image(size: 56)
            }
        } description: {
            Text("Create a library, or open a library file you already have. You can also drop a library file here.")
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Group {
                    Button("New Library…") { launch.requestNewLibrary() }
                    Button("Open Other…") { launch.chooseLibraryFile() }
                }
                .disabled(launch.isBusy)
                .help(launch.busyReason ?? "")
                Spacer()
                if let refusal = selectedRow?.openRefusal {
                    Text(refusal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Open") {
                    if let row = selectedRow { Task { await launch.openRow(row) } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!(selectedRow?.canOpen ?? false))
                .help(selectedRow?.openRefusal ?? "Open the selected library")
            }
            .controlSize(.large)
            HStack(spacing: Spacing.s) {
                // Same registry setting as Settings ▸ General (UC-WIN-04).
                Toggle("Open the last library at launch", isOn: Binding(
                    get: { launch.rememberLastLibrary },
                    set: { launch.setRememberLastLibrary($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Text("Drop a library file (.mlibm) here to open it")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = launch.removalMessage {
                // The picker's own status line: the window's status bar and Undo belong to an
                // open library (IMP: Remove from List is undoable for the session, no alert).
                HStack(spacing: Spacing.s) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Undo") { launch.undoRemoval() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: Helpers

    private func selectInitialRow() {
        selection = LibraryPickerRows.initialSelection(in: rows, focus: launch.pickerFocus?.url)
    }

    /// Track counts and library folders, read-only and best effort.
    private func loadFacts() async {
        let wanted = rows.filter { $0.state == .available || $0.state == .needsSetup }
        let loaded: [String: LibraryPickerFacts] = await Task.detached(priority: .utility) {
            var result: [String: LibraryPickerFacts] = [:]
            for row in wanted {
                let database = row.kind == .legacy ? row.url : LibraryPackage.databaseURL(in: row.url)
                if let facts = LibraryPickerFacts.read(databaseAt: database) { result[row.id] = facts }
            }
            return result
        }.value
        facts = loaded
    }
}

/// One picker row: icon, name, location, state or facts, last opened; a selected problem row
/// explains itself and carries its actions (`launch.html` `.lrow` + `.lx`).
private struct LibraryPickerRowView: View {
    let row: LibraryPickerRow
    let facts: LibraryPickerFacts?
    let isSelected: Bool
    let note: String?
    let launch: LibraryLaunchCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.m) {
                LibraryFileIcon.image(size: 32)
                    .opacity(row.canOpen ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.listedName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(row.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.url.path)
                    stateLine
                }
                Spacer(minLength: Spacing.s)
                if let opened = row.lastOpenedAt {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Last opened")
                        Text(opened, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                inlineActions
            }
            if isSelected, let explanation = row.explanation {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .mismatch(let details) = row.state {
                        HStack(spacing: Spacing.s) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                        }
                        DetailsDisclosure(text: details)
                    }
                    if case .setupInterrupted(let details) = row.state {
                        DetailsDisclosure(text: details)
                    }
                }
                .padding(.leading, 32 + Spacing.m)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32 + Spacing.m)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.listedName)
        .accessibilityValue(row.stateText ?? "")
    }

    @ViewBuilder
    private var stateLine: some View {
        switch row.state {
        case .notFound:
            StateLabel(text: "Not found", systemImage: "questionmark.folder", tint: .red)
                .font(.caption)
        case .notConnected:
            StateLabel(text: row.stateText ?? "", systemImage: "externaldrive.badge.xmark", tint: .orange)
                .font(.caption)
        case .mismatch:
            StateLabel(text: row.stateText ?? "", systemImage: "exclamationmark.triangle", tint: .orange)
                .font(.caption)
        case .setupInterrupted:
            StateLabel(text: "Setup interrupted", systemImage: "exclamationmark.triangle", tint: .orange)
                .font(.caption)
        case .available, .needsSetup:
            if let caption = facts?.caption(isLegacy: row.kind == .legacy) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if row.kind == .legacy {
                Text("not yet a library file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A problem row's fixes (UC-STATE §15.1 "Fix" column).
    @ViewBuilder
    private var inlineActions: some View {
        switch row.state {
        case .notConnected:
            Button("Try Again") { Task { await launch.tryAgain(row) } }
        case .notFound:
            HStack(spacing: Spacing.xs) {
                Button("Locate…") { launch.locate(row) }
                Button("Remove from List") { launch.removeFromList(row) }
            }
        case .needsSetup:
            Button("Set Up…") { launch.offerAdoption() }
        case .setupInterrupted:
            Button("Try Again") { Task { await launch.retryInterruptedSetup() } }
                .disabled(launch.isBusy)
        case .available, .mismatch:
            EmptyView()
        }
    }
}
