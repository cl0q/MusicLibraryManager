import SwiftUI

/// The Activity window (W-ACTIVITY, UC-JOB-06, UC-WIN-02): `Window("Activity", id: "activity")`,
/// Window ▸ Activity ⌥⌘0, available in every launch state. Tabs `Operations · Logs`
/// (remembered). Selection commands are disabled while it is key (UC-MENU-04): it publishes
/// none of the main window's focused values.
enum ActivityWindow {
    static let id = "activity"
    static let title = "Activity"
}

struct ActivityWindowView: View {
    var center: ActivityCenter = .shared
    @Bindable private var router = ActivityRouter.shared
    @Environment(\.container) private var container
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if !container.isInitialized {
                noLibraryLine
                Divider()
            }
            switch router.tab {
            case .operations:
                ActivityOperationsView(center: center)
            case .logs:
                ActivityLogsView()
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $router.tab) {
                    ForEach(ActivityRouter.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .navigationTitle(ActivityWindow.title)
    }

    /// W-ACTIVITY no-library state.
    private var noLibraryLine: some View {
        HStack(spacing: Spacing.s) {
            Text("No library is open. Operations of the last session are shown; new work starts when a library is open. Logs are complete.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Button("Choose Library…") { openWindow(id: MainWindow.id) }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
    }
}

// MARK: - Operations (P-ACTIVITY-OPS)

/// Scope `All · Running · Needs attention · Finished` with live counts, `Retry All`, the
/// operations table and the per-item detail of the selected row.
struct ActivityOperationsView: View {
    let center: ActivityCenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("activity.window.scope") private var scopeRaw = ActivityScope.all.rawValue
    @State private var selection: UUID?
    @State private var clearQueueTarget: ActivityOperation?

    private var scope: Binding<ActivityScope> {
        Binding(get: { ActivityScope(rawValue: scopeRaw) ?? .all }, set: { scopeRaw = $0.rawValue })
    }

    var body: some View {
        let all = center.allOperations
        let rows = all.filter { scope.wrappedValue.contains($0) }
        VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                Picker("Show", selection: scope) {
                    ForEach(ActivityScope.allCases) { item in
                        Text("\(item.title) \(all.filter(item.contains).count.formatted(.number))").tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                let retryable = ActivityPresentation.attentionGroups(center).filter { !$0.isWaiting && $0.isRetryable }
                Button("Retry All") {
                    for group in retryable { ActivitySubjectNavigator.retry(group, center: center) }
                }
                .disabled(retryable.isEmpty)
                .help(retryable.isEmpty ? "Nothing can be retried now." : "Retries every failed item whose cause may have gone away.")
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.s)
            Divider()
            if center.historyLoadFailed {
                ContentUnavailableView {
                    Label("Can’t load the operation history", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The library didn’t answer. Running work is not affected, and the logs are still available.")
                } actions: {
                    Button("Try Again") { Task { await center.reloadHistory() } }
                    Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                }
            } else if all.isEmpty {
                ContentUnavailableView {
                    Label("No activity", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Downloads, imports, syncs, scans, analyses and backups appear here while they run, and stay with their result.")
                }
            } else if rows.isEmpty {
                ContentUnavailableView("Nothing in “\(scope.wrappedValue.title)”", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Choose All to see every operation."))
            } else {
                VSplitView {
                    table(rows)
                        .frame(minHeight: 160)
                    ActivityOperationDetail(operation: selectedOperation(in: rows), center: center,
                                            open: open, showLogs: showLogs)
                        .frame(minHeight: 140, idealHeight: 240)
                }
            }
        }
        .onAppear {
            if let requested = ActivityRouter.shared.selectedOperationID {
                selection = requested
                ActivityRouter.shared.selectedOperationID = nil
            }
        }
        .confirmationDialog(ActivityQueueCopy.clearTitle(waiting: clearQueueTarget.map(ActivityPresentation.waitingItems) ?? 0),
                            isPresented: Binding(get: { clearQueueTarget != nil }, set: { if !$0 { clearQueueTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Clear Waiting", role: .destructive) {
                clearQueueTarget?.controls.clearWaiting?()
                clearQueueTarget = nil
            }
            Button("Cancel", role: .cancel) { clearQueueTarget = nil }
        } message: {
            Text(ActivityQueueCopy.clearMessage(waiting: clearQueueTarget.map(ActivityPresentation.waitingItems) ?? 0))
        }
    }

    private func selectedOperation(in rows: [ActivityOperation]) -> ActivityOperation? {
        guard let selection else { return rows.first }
        return rows.first { $0.id == selection } ?? center.operation(id: selection)
    }

    private func table(_ rows: [ActivityOperation]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Kind") { op in
                Label(op.kind.label, systemImage: op.kind.systemImage)
            }
            .width(min: 80, ideal: 96, max: 120)
            TableColumn("Operation") { op in
                VStack(alignment: .leading, spacing: 0) {
                    Text(op.title).lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        if op.isAutomatic { Text("Automatic") }
                        if op.isAutomatic, op.subject.linkLabel != nil { Text("·") }
                        ActivitySubjectLink(subject: op.subject) { open(op.subject) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("State") { op in
                ActivityStateLabel(state: op.state)
            }
            .width(min: 90, ideal: 104, max: 120)
            TableColumn("Progress") { op in
                ActivityProgressCell(operation: op)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Started") { op in
                Text(ActivityPresentation.startedText(op.startedAt))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Result") { op in
                if let result = ActivityPresentation.resultText(op) {
                    Text(result).lineLimit(2)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 200)
            TableColumn("") { op in
                if op.state.isActive {
                    ActivityControlButtons(operation: op, center: center, clearQueue: { clearQueueTarget = op })
                }
            }
            .width(min: 60, ideal: 170)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let op = center.operation(id: id) {
                ActivityOperationMenu(operation: op, center: center, open: open, showLogs: showLogs,
                                      clearQueue: { clearQueueTarget = op })
            }
        } primaryAction: { ids in
            if let id = ids.first, let op = center.operation(id: id) { open(op.subject) }
        }
    }

    private func open(_ subject: ActivitySubject) {
        ActivitySubjectNavigator.open(subject, openWindow: openWindow, openSettings: openSettings)
    }

    private func showLogs(_ operation: ActivityOperation) {
        ActivityRouter.shared.showLogs(for: operation)
    }
}

/// The window's scope (UC-SCOPE-02): Running includes Queued and Paused.
enum ActivityScope: String, CaseIterable, Identifiable {
    case all, running, attention, finished
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .running: "Running"
        case .attention: "Needs attention"
        case .finished: "Finished"
        }
    }

    func contains(_ op: ActivityOperation) -> Bool {
        switch self {
        case .all: true
        case .running: op.state.isActive
        case .attention: op.state.isTerminal && op.needsAttention && op.dismissedAt == nil
        case .finished: op.state.isTerminal
        }
    }
}

/// State word + symbol (UC §15.6) — always text; only `Failed` tints its symbol (UC-COLOR-05).
struct ActivityStateLabel: View {
    let state: ActivityState

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if state == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: state.systemImage)
                    .foregroundStyle(state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Text(state.word)
                .foregroundStyle(.secondary)
        }
    }
}

struct ActivityProgressCell: View {
    let operation: ActivityOperation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if operation.state.isActive {
                if operation.state == .running, operation.progress.isDeterminate,
                   let text = ActivityPresentation.progressText(operation.progress) {
                    Text(text).monospacedDigit()
                    if let fraction = operation.progress.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    }
                } else if let line = ActivityPresentation.activeLine(operation)
                            ?? ActivityPresentation.progressText(operation.progress) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let duration = operation.duration {
                Text(ActivityPresentation.durationText(duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - CM-OPS-ROW

/// `Show ‹Subject›` — `Retry Failed` · `Pause` · `Cancel` / `Cancel After This Track` —
/// `Show in Logs` · `Copy Summary` — `Remove from History`. Items that don't apply are absent.
struct ActivityOperationMenu: View {
    let operation: ActivityOperation
    let center: ActivityCenter
    let open: (ActivitySubject) -> Void
    let showLogs: (ActivityOperation) -> Void
    var clearQueue: () -> Void = {}

    var body: some View {
        if let label = operation.subject.showLabel {
            Section { Button(label) { open(operation.subject) } }
        }
        let failing = center.stillFailing(operation)
        let canRetry = operation.state.isTerminal && !failing.isEmpty
            && (operation.controls.retry != nil || center.retryHandler != nil)
        let canRunAgain = operation.state.isTerminal && operation.controls.runAgain != nil
        if canRetry || canRunAgain || (operation.state.isActive && (operation.controls.canPause
            || operation.controls.canCancel || operation.state == .queued || operation.controls.clearWaiting != nil)) {
            Section {
                if canRetry { Button("Retry Failed") { center.retryFailed(operation.id) } }
                if canRunAgain { Button("Run Again") { operation.controls.runAgain?() } }
                if operation.state.isActive {
                    if operation.controls.canPause {
                        if operation.state == .paused {
                            Button("Resume") { center.resume(operation.id) }
                        } else {
                            Button("Pause") { center.pause(operation.id) }
                        }
                    }
                    if operation.controls.clearWaiting != nil, (operation.progress.waiting ?? 0) > 0 {
                        Button("Clear Waiting…", action: clearQueue)
                    }
                    if operation.controls.canCancel || operation.state == .queued {
                        Button(operation.state == .queued ? "Cancel" : operation.controls.cancelStyle.title) {
                            center.cancel(operation.id)
                        }
                    }
                }
            }
        }
        Section {
            Button("Show in Logs") { showLogs(operation) }
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ActivityPresentation.summaryText(operation), forType: .string)
            }
        }
        if operation.state.isTerminal {
            Section { Button("Remove from History") { center.removeFromHistory(operation.id) } }
        }
    }
}

// MARK: - Detail (P-ACTIVITY-OPS.N02)

/// Per-item outcomes of the selected operation, each with a plain reason, and the way to its
/// log lines.
struct ActivityOperationDetail: View {
    let operation: ActivityOperation?
    let center: ActivityCenter
    let open: (ActivitySubject) -> Void
    let showLogs: (ActivityOperation) -> Void

    var body: some View {
        if let operation {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.s) {
                    Text(operation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(headerFacts(operation))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    let failing = center.stillFailing(operation)
                    if operation.state.isTerminal, !failing.isEmpty,
                       operation.controls.retry != nil || center.retryHandler != nil {
                        Button("Retry Failed (\(failing.count.formatted(.number)))") {
                            center.retryFailed(operation.id)
                        }
                    }
                    if let label = operation.subject.showLabel {
                        Button(label) { open(operation.subject) }
                    }
                    Button("Show in Logs") { showLogs(operation) }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.s)
                Divider()
                if let items = operation.result?.items, !items.isEmpty {
                    Table(items.enumerated().map { NumberedOutcome(id: $0.offset, element: $0.element) }) {
                        TableColumn("#") { pair in
                            Text((pair.id + 1).formatted(.number))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 28, ideal: 36, max: 48)
                        TableColumn("Title") { pair in Text(pair.element.title).lineLimit(1) }
                        TableColumn("Outcome") { pair in
                            HStack(spacing: Spacing.xxs) {
                                if pair.element.isFailure {
                                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                                }
                                Text(pair.element.word)
                                if let reason = pair.element.reason {
                                    Text("· \(reason)").foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                        }
                    }
                } else {
                    Form {
                        LabeledContent("Operation", value: operation.title)
                        if operation.subject.linkLabel != nil {
                            LabeledContent("Subject") {
                                ActivitySubjectLink(subject: operation.subject) { open(operation.subject) }
                            }
                            .help(operation.subject.isMissing ? "It no longer exists." : "")
                        }
                        LabeledContent("State") { ActivityStateLabel(state: operation.state) }
                        LabeledContent("Started", value: ActivityPresentation.startedText(operation.startedAt))
                        if operation.state.isActive, let line = ActivityPresentation.activeLine(operation) {
                            LabeledContent("Now", value: line)
                        }
                        LabeledContent("Result", value: ActivityPresentation.resultText(operation) ?? "—")
                        ForEach(operation.result?.failureGroups ?? [], id: \.self) { group in
                            LabeledContent(group.cause, value: group.count.formatted(.number))
                        }
                    }
                    .formStyle(.grouped)
                }
            }
        } else {
            Text("Select an operation to see its details.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headerFacts(_ op: ActivityOperation) -> String {
        var parts = [op.state.word]
        if op.state.isActive, let progress = ActivityPresentation.progressText(op.progress) { parts.append(progress) }
        parts.append("started \(ActivityPresentation.startedText(op.startedAt))")
        return parts.joined(separator: " · ")
    }
}

private struct NumberedOutcome: Identifiable {
    let id: Int
    let element: ActivityItemOutcome
}
